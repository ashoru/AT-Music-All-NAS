import SwiftUI

/// 播放界面的「歌词同步校准」面板。
///
/// 设计取向：这一版把「粗调」做成两根最容易盲按的大胶囊（±0.5s），
/// 「微调」放在 ±0.1s，滑杆留给需要精细对齐的偏执场景；上方实时读数，
/// 下方预览窗口直接显示**即将写进文件的时间轴**，避免「调好了但存下去是另一回事」。
struct LyricsSyncSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var theme: ThemeStore

    @ObservedObject private var offsetStore = LyricOffsetStore.shared
    @Environment(\.dismiss) private var dismiss

    let song: Song
    var onBaked: ((String) -> Void)? = nil

    @State private var rawLyrics: String = ""
    @State private var parsedLines: [LyricLine] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var message: String = ""

    private var identityKey: String { song.identityKey }

    /// 读一下 revision 让面板随逐曲偏移变化即时重绘。
    private var offset: Double {
        _ = offsetStore.revision
        return offsetStore.offset(for: identityKey)
    }

    private var isCustomOffset: Bool { offsetStore.hasCustomOffset(for: identityKey) }

    private var writebackTarget: String {
        switch song.source {
        case .synology:
            return "校准结果会写回群晖 NAS 上的原文件"
        case .local:
            return "校准结果会写进本地音频（内嵌歌词）并同步 .lrc"
        default:
            return "校准结果会写进本地离线音频（内嵌歌词）并同步 .lrc"
        }
    }

    var body: some View {
        ZStack {
            Color.atmusicBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    offsetCard
                    coarseControls
                    fineControls
                    sliderRow
                    previewCard
                    if !message.isEmpty {
                        Text(message)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 26)
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.fraction(0.72), .large], dragIndicator: true))
        .task { await loadLyrics() }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "metronome")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 38, height: 38)
                .background(Color.atmusicAmber.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("歌词同步校准")
                    .font(ATMusicFont.appFont(16, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Text(song.artists.isEmpty ? song.name : "\(song.name) · \(song.artists)")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                ATMusicHaptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.atmusicComment.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 4)
    }

    private var offsetCard: some View {
        VStack(spacing: 6) {
            Text(LyricOffsetStore.text(for: offset))
                .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(abs(offset) < 0.001 ? Color.atmusicLabel : Color.atmusicAmber)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: offset)
            Text(isCustomOffset ? "本曲已单独校准（其他歌曲不受影响）" : "正在使用全局默认偏移")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private var coarseControls: some View {
        HStack(spacing: 10) {
            coarseButton(title: "−0.5s", detail: "歌词延后", delta: -LyricOffsetStore.coarseStep)
            coarseButton(title: "+0.5s", detail: "歌词提前", delta: LyricOffsetStore.coarseStep)
        }
    }

    private func coarseButton(title: String, detail: String, delta: Double) -> some View {
        Button {
            apply(delta: delta)
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.atmusicLabel)
                Text(detail)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                ATMusicLiquidSelectionSurface(
                    shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                    accent: .atmusicAmber
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail + " 0.5 秒")
    }

    private var fineControls: some View {
        HStack(spacing: 10) {
            fineButton(title: "−0.1s", delta: -LyricOffsetStore.fineStep)
            fineButton(title: "+0.1s", delta: LyricOffsetStore.fineStep)
            Button {
                ATMusicHaptics.select()
                withAnimation(.snappy(duration: 0.18)) {
                    offsetStore.reset(for: identityKey)
                }
                message = "已归零"
            } label: {
                Text("归零")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func fineButton(title: String, delta: Double) -> some View {
        Button {
            apply(delta: delta)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.atmusicLabel)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var sliderRow: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { offset },
                    set: { offsetStore.set($0, for: identityKey) }
                ),
                in: -LyricOffsetStore.limit...LyricOffsetStore.limit,
                step: 0.05
            )
            .tint(Color.atmusicAmber)
            HStack {
                Text("−12s").font(ATMusicFont.appFont(10)).foregroundStyle(Color.atmusicComment.opacity(0.7))
                Spacer()
                Text("0").font(ATMusicFont.appFont(10)).foregroundStyle(Color.atmusicComment.opacity(0.7))
                Spacer()
                Text("+12s").font(ATMusicFont.appFont(10)).foregroundStyle(Color.atmusicComment.opacity(0.7))
            }
        }
        .padding(.horizontal, 4)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间轴预览")
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicComment)
                Spacer()
                if !parsedLines.isEmpty {
                    Text("写入后时间轴")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicAmber.opacity(0.9))
                }
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取歌词…")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else if parsedLines.isEmpty {
                Text("这首歌还没有可用歌词，先在歌词搜索里挑一份再回来校准。")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(previewRows, id: \.id) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.timeLabel)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.atmusicAmber.opacity(row.isCurrent ? 1 : 0.55))
                                .frame(width: 52, alignment: .leading)
                            Text(row.text.isEmpty ? "♪" : row.text)
                                .font(ATMusicFont.appFont(row.isCurrent ? 14 : 13, row.isCurrent ? .semibold : .regular))
                                .foregroundStyle(row.isCurrent ? Color.atmusicLabel : Color.atmusicComment)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            GlassButton(
                title: isSaving ? "正在写回文件…" : "校准并写回文件",
                systemName: "square.and.arrow.down.on.square",
                prominent: true
            ) {
                save()
            }
            .disabled(isSaving || parsedLines.isEmpty || abs(offset) < 0.001)
            .opacity(isSaving || parsedLines.isEmpty || abs(offset) < 0.001 ? 0.5 : 1)

            Text(writebackTarget + "；写入后本曲偏移自动归零，时间轴已固化进歌词本身。")
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
    }

    // MARK: - 预览数据

    private struct PreviewRow: Identifiable {
        let id: Int
        let timeLabel: String
        let text: String
        let isCurrent: Bool
    }

    private var previewRows: [PreviewRow] {
        guard !parsedLines.isEmpty else { return [] }
        let effectiveProgress = max(0, clock.progress + offset)
        var current = 0
        for (index, line) in parsedLines.enumerated() where line.time <= effectiveProgress {
            current = index
        }
        let lower = max(0, current - 1)
        let upper = min(parsedLines.count - 1, current + 3)
        guard lower <= upper else { return [] }
        return (lower...upper).map { index in
            let line = parsedLines[index]
            let baked = max(0, line.time - offset)
            return PreviewRow(
                id: index,
                timeLabel: Self.timeLabel(baked),
                text: line.text,
                isCurrent: index == current
            )
        }
    }

    private static func timeLabel(_ time: Double) -> String {
        let total = Int(max(0, time))
        let fraction = Int(((max(0, time) - Double(total)) * 100).rounded())
        return String(format: "%02d:%02d.%02d", total / 60, total % 60, min(99, fraction))
    }

    // MARK: - 动作

    private func apply(delta: Double) {
        ATMusicHaptics.select()
        _ = withAnimation(.snappy(duration: 0.18)) {
            offsetStore.adjust(by: delta, for: identityKey)
        }
        message = LyricOffsetStore.text(for: offset)
    }

    private func loadLyrics() async {
        let raw = await SongLyricsLoader.rawLyricString(for: song) ?? ""
        let lines = LyricParser.parse(raw)
        await MainActor.run {
            rawLyrics = raw
            parsedLines = lines
            isLoading = false
        }
    }

    private func save() {
        guard !isSaving else { return }
        let raw = rawLyrics
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "没有可写回的歌词文本"
            return
        }
        let currentOffset = offset
        isSaving = true
        message = "正在烘焙时间轴并写回…"
        Task {
            let outcome = await LyricWriteback.bakeAndSave(song: song, raw: raw, offset: currentOffset)
            await MainActor.run {
                isSaving = false
                message = outcome.message
                guard outcome.wroteToFile else { return }
                rawLyrics = outcome.bakedLyrics
                parsedLines = LyricParser.parse(outcome.bakedLyrics)
                offsetStore.reset(for: identityKey)
                player.updateCurrentLyrics(parsedLines, for: identityKey)
                onBaked?(outcome.bakedLyrics)
                ATMusicHaptics.success()
                ToastCenter.shared.show(outcome.message)
            }
        }
    }
}
