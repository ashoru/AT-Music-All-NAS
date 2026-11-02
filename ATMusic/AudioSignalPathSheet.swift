import SwiftUI

/// 发烧级音频信号通路与规格看板（对标 Roon / Aurender 信号流体系，原生极简低功耗）
struct AudioSignalPathSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let song: Song?
    @State private var isSavingLyrics = false

    private var isNAS: Bool {
        song?.source == .synology
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

                ScrollView {
                    VStack(spacing: 16) {
                        headerSummaryCard

                        signalPathCard

                        if isNAS {
                            nasAdvancedCard
                        }

                        featuresCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("音频信号通路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(isNAS ? Color.atmusicAmber : theme.accent.highlight)
                }
            }
        }
    }

    // MARK: - 顶部概览

    private var headerSummaryCard: some View {
        HStack(spacing: 14) {
            CoverImage(url: song?.coverURL, size: 68, cornerRadius: 14)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(song?.name ?? "未在播放")
                    .font(ATMusicFont.appFont(17, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)

                Text(song?.artists ?? "未知艺术家")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(isNAS ? Color.atmusicAmber : Color.green)
                        .frame(width: 7, height: 7)

                    Text(isNAS ? "Bit-Perfect · 原盘无损直出" : "官方高解析原生接口")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(isNAS ? Color.atmusicAmber : Color.green)
                }
            }
            Spacer()
        }
        .padding(14)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    // MARK: - 信号链路核心卡片

    private var signalPathCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(isNAS ? Color.atmusicAmber : theme.accent.highlight)
                Text("信号流链路 (Audio Signal Path)")
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("0 损耗直通")
                    .font(ATMusicFont.appFont(11, .medium))
                    .foregroundStyle(Color.atmusicComment)
            }

            VStack(spacing: 12) {
                stepRow(
                    step: "1",
                    title: "存储源头 (Source)",
                    detail: sourceDescription,
                    badge: isNAS ? "私有母带" : (song?.source.displayName ?? "在线")
                )

                stepRow(
                    step: "2",
                    title: "传输管道 (Transport)",
                    detail: transportDescription,
                    badge: isNAS ? (synology.isLanActive ? "局域网千兆" : "公网 DDNS") : "官方 CDN"
                )

                stepRow(
                    step: "3",
                    title: "解码核心 (Engine)",
                    detail: "iOS AVFoundation 硬件 CoreAudio 直通解码 · 100% 原始采样率",
                    badge: "硬件直解"
                )

                stepRow(
                    step: "4",
                    title: "输出终点 (Output)",
                    detail: "设备音频总线 · Bit-Perfect 样点保真输出",
                    badge: "无重采样"
                )
            }
        }
        .padding(16)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private func stepRow(step: String, title: String, detail: String, badge: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isNAS ? Color.atmusicAmber.opacity(0.18) : theme.accent.highlight.opacity(0.16))
                    .frame(width: 24, height: 24)
                Text(step)
                    .font(ATMusicFont.appFont(12, .bold))
                    .foregroundStyle(isNAS ? Color.atmusicAmber : theme.accent.highlight)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Text(badge)
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(isNAS ? Color.atmusicAmber : Color.atmusicComment)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04), in: Capsule())
                }

                Text(detail)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(2)
            }
        }
    }

    private var sourceDescription: String {
        if isNAS {
            let path = song?.synologyPath ?? "群晖 NAS 原盘文件"
            let ext = (path as NSString).pathExtension.uppercased()
            return "\(ext.isEmpty ? "FLAC" : ext) 原盘无损 · \(path)"
        }
        return "官方正版流媒体音轨 · \(song?.source.displayName ?? "") 原生接口"
    }

    private var transportDescription: String {
        if isNAS {
            if synology.isLanActive {
                return "家庭局域网千兆直连 · 延迟约 \(synology.lanLatencyMs.map { "\($0)ms" } ?? "1ms") · 原生无转码"
            } else {
                return "外部公网 SSL 直连 · 延迟约 \(synology.wanLatencyMs.map { "\($0)ms" } ?? "30ms") · 原盘直通"
            }
        }
        return "HTTPS 高速 CDN 直出 · 自动网络缓冲保障"
    }

    // MARK: - NAS 专属高级操作

    private var nasAdvancedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NAS 私有云生态反哺")
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)

            if let targetSong = song, !player.currentLyrics.isEmpty {
                Button {
                    saveLyricsToNAS(targetSong)
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                        Text(isSavingLyrics ? "正在保存..." : "将当前在线歌词持久化写回 NAS")
                            .font(ATMusicFont.appFont(13, .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(12)
                    .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isSavingLyrics)
            } else {
                Text("当前歌曲已包含本地内嵌元数据")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(16)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private func saveLyricsToNAS(_ targetSong: Song) {
        guard !player.currentLyrics.isEmpty else { return }
        isSavingLyrics = true
        let lrcText = player.currentLyrics.map { line in
            let mins = Int(line.time) / 60
            let secs = Int(line.time) % 60
            let millis = Int((line.time.truncatingRemainder(dividingBy: 1)) * 100)
            return String(format: "[%02d:%02d.%02d]%@", mins, secs, millis, line.text)
        }.joined(separator: "\n")

        Task {
            // 内嵌标签 + 同名 .lrc + 歌词库 + 本机缓存一起写，避免只更新其中一层导致下次播放还是旧歌词
            let report = await LyricsPersistence.save(song: targetSong, raw: lrcText)
            await MainActor.run {
                isSavingLyrics = false
                ToastCenter.shared.show(report.isSuccess ? report.message : "写回失败：\(report.message)")
            }
        }
    }

    // MARK: - 连续性与功耗特性

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("播放器特性与功耗保护")
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)

            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.checkmark.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.green)
                Text("锁屏与后台超低功耗休眠（硬件时钟托管）")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }

            HStack(spacing: 8) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.green)
                Text("双播放器热备池就绪（下一首秒开预热）")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(16)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }
}


// MARK: - 音质与信号链路微标胶囊

struct AudioQualityCapsule: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    let song: Song?
    @State private var showSignalPath = false

    private var isNAS: Bool {
        song?.source == .synology
    }

    private var labelText: String {
        if isNAS {
            let path = song?.synologyPath ?? ""
            let ext = (path as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "原盘无损" : "\(ext) 原盘"
        }
        return "Hi-Res"
    }

    var body: some View {
        if song != nil {
            Button {
                ATMusicHaptics.tap()
                showSignalPath = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isNAS ? "waveform.path.ecg" : "sparkles")
                        .font(.system(size: 8, weight: .bold))
                    Text(labelText)
                        .font(ATMusicFont.appFont(9, .bold))
                }
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(
                    Capsule()
                        .fill(isNAS ? Color.atmusicAmber.opacity(0.18) : Color.white.opacity(0.18))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isNAS ? Color.atmusicAmber.opacity(0.4) : Color.white.opacity(0.3), lineWidth: 0.8)
                )
                .foregroundStyle(isNAS ? Color.atmusicAmber : Color.white)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSignalPath) {
                AudioSignalPathSheet(song: song)
                    .presentationDetents(DeviceLayoutHelper.isIPad ? [.large] : [.medium, .large])
                    .environmentObject(theme)
                    .environmentObject(player)
            }
        }
    }
}
