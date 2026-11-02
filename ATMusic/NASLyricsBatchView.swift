import SwiftUI
import UniformTypeIdentifiers

/// NAS 批量维护工作台：歌词写回 + 专辑封面补全。
///
/// 流程统一为「选范围 → 搜索匹配 → 逐条预览/手动换候选 → 写入」：
/// 搜索结果不再只能照单全收，每一条都能点开换一份；
/// 封面写入走「下载原文件 → 内嵌封面 → 覆盖回传」，并额外给同目录同专辑补一张 cover.jpg。
struct NASBatchMaintenanceSheet: View {
    enum Mode: Int, CaseIterable, Identifiable {
        case lyrics
        case covers

        var id: Int { rawValue }
        var title: String { self == .lyrics ? "歌词写回" : "专辑封面" }
    }

    enum LyricsStrategy: Int, CaseIterable, Identifiable {
        case missingOnly
        case overwriteAll

        var id: Int { rawValue }
        var title: String { self == .missingOnly ? "只补缺失" : "全部重写" }
        var hint: String {
            self == .missingOnly ? "已有歌词的歌曲直接跳过，最安全" : "为范围内所有歌曲重新匹配并覆盖"
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var synology = SynologyAPI.shared

    @StateObject private var lyricsRunner = NASLyricsBatchRunner()
    @StateObject private var coverRunner = NASCoverBatchRunner()

    @State private var mode: Mode = .lyrics
    @State private var strategy: LyricsStrategy = .missingOnly
    @State private var libraryLimit = 50
    @State private var selectedSongs: [Song] = []
    @State private var selectionLabel: String = ""
    @State private var showFolderPicker = false
    @State private var isPreparingLibrary = false
    @State private var message = ""
    @State private var lyricPickerID: String?
    @State private var coverPickerID: String?
    @State private var embedIntoFiles = true
    @State private var writeFolderCoverFile = true

    private let limitOptions: [Int] = [20, 50, 100, 300]

    private var usingLibrary: Bool { selectedSongs.isEmpty }
    private var busy: Bool { lyricsRunner.isWorking || coverRunner.isWorking }

    var body: some View {
        ZStack {
            Color.atmusicBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 14) {
                        modePicker
                        scopeCard
                        if mode == .lyrics {
                            lyricsOptionsCard
                        } else {
                            coverOptionsCard
                        }
                        if !message.isEmpty { messageRow }
                        if mode == .lyrics {
                            lyricsSection
                        } else {
                            coversSection
                        }
                        actionBar
                        footerNote
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
        .sheet(isPresented: $showFolderPicker) {
            NASFolderPickerSheet { songs, label in
                selectedSongs = songs
                selectionLabel = label
                message = songs.isEmpty ? "" : "已选 \(songs.count) 首：\(label)"
            }
        }
        .sheet(isPresented: Binding(get: { lyricPickerID != nil }, set: { if !$0 { lyricPickerID = nil } })) {
            if let id = lyricPickerID, let item = lyricsRunner.item(id: id) {
                NASLyricCandidateSheet(
                    title: item.song.name,
                    subtitle: item.song.artists,
                    candidates: item.candidates,
                    selectedIndex: item.selectedIndex
                ) { index in
                    lyricsRunner.selectCandidate(index, for: id)
                    lyricPickerID = nil
                }
            }
        }
        .sheet(isPresented: Binding(get: { coverPickerID != nil }, set: { if !$0 { coverPickerID = nil } })) {
            if let id = coverPickerID, let target = coverRunner.target(id: id) {
                NASCoverCandidateSheet(
                    album: target.album,
                    artist: target.artist,
                    candidates: target.candidates,
                    selectedIndex: target.selectedIndex
                ) { index in
                    coverRunner.selectCandidate(index, for: id)
                    coverPickerID = nil
                }
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 38, height: 38)
                .background(Color.atmusicAmber.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("NAS 批量维护")
                    .font(ATMusicFont.appFont(16, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Text("歌词写回 · 专辑封面 · 可选目录与歌曲")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
            Button {
                ATMusicHaptics.tap()
                if busy {
                    lyricsRunner.cancel()
                    coverRunner.cancel()
                }
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.atmusicComment.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            ForEach(Mode.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .disabled(busy)
    }

    // MARK: 范围

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                Text("处理范围")
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicComment)
                Spacer()
                if !selectedSongs.isEmpty {
                    Text("\(selectedSongs.count) 首 · \(Self.albumCount(selectedSongs)) 张专辑")
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(Color.atmusicAmber)
                }
            }

            HStack(spacing: 8) {
                Button {
                    ATMusicHaptics.tap()
                    showFolderPicker = true
                } label: {
                    Label(selectedSongs.isEmpty ? "选择文件夹 / 歌曲" : "重新选择", systemImage: "folder")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    ATMusicHaptics.select()
                    selectedSongs = []
                    selectionLabel = ""
                    message = ""
                } label: {
                    Text("整个曲库")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(usingLibrary && mode == .lyrics ? Color.atmusicAmber : Color.atmusicComment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            usingLibrary && mode == .lyrics ? Color.atmusicAmber.opacity(0.16) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(busy || mode == .covers)
                .opacity(mode == .covers ? 0.45 : 1)
            }

            Text(scopeHint)
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            if !synology.isLoggedIn {
                Text("尚未连接群晖 NAS，请先在「设置 → 群晖 NAS」登录。")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private var scopeHint: String {
        if mode == .covers {
            return selectedSongs.isEmpty
                ? "封面补全需要先选定范围：点左侧「选择文件夹 / 歌曲」，可勾选单曲，也可以把整个目录（含子目录）一次加入。"
                : "当前作用于：\(selectionLabel)"
        }
        return selectedSongs.isEmpty
            ? "当前作用于整个 NAS 曲库（按上限取一批，优先没有曲目号的散装文件）。"
            : "当前作用于：\(selectionLabel)"
    }

    // MARK: 选项

    private var lyricsOptionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("写入策略")
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicComment)
                Picker("写入策略", selection: $strategy) {
                    ForEach(LyricsStrategy.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                Text(strategy.hint)
                    .font(ATMusicFont.appFont(10))
                    .foregroundStyle(Color.atmusicComment.opacity(0.85))
            }

            if usingLibrary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本次处理上限")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                    HStack(spacing: 8) {
                        ForEach(limitOptions, id: \.self) { value in
                            Button {
                                ATMusicHaptics.select()
                                libraryLimit = value
                            } label: {
                                Text("\(value) 首")
                                    .font(ATMusicFont.appFont(12, libraryLimit == value ? .semibold : .regular))
                                    .foregroundStyle(libraryLimit == value ? Color.atmusicLabel : Color.atmusicComment)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        libraryLimit == value ? Color.atmusicAmber.opacity(0.18) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private var coverOptionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("写入方式")
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicComment)
            Toggle(isOn: $embedIntoFiles) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("内嵌到每首歌曲文件")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("下载原文件 → 写封面 → 回传覆盖；换播放器、拷出来都带封面（较慢）")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .tint(Color.atmusicAmber)
            .disabled(busy)

            Toggle(isOn: $writeFolderCoverFile) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("同目录同专辑另写 cover.jpg")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("给按文件夹取封面的播放器兜底；一个目录一次会话只传一张")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .tint(Color.atmusicAmber)
            .disabled(busy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private var messageRow: some View {
        Text(message)
            .font(ATMusicFont.appFont(12))
            .foregroundStyle(Color.atmusicComment)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: 歌词列表

    @ViewBuilder
    private var lyricsSection: some View {
        if !lyricsRunner.items.isEmpty {
            progressHeader(
                title: lyricsRunner.isWriting ? "正在写入…" : "匹配结果",
                done: lyricsRunner.isWriting ? lyricsRunner.writtenCount : lyricsRunner.matchedCount,
                total: lyricsRunner.items.count,
                detail: lyricsRunner.summary
            )
            LazyVStack(spacing: 6) {
                ForEach(lyricsRunner.items) { item in
                    lyricRow(item)
                }
            }
        }
    }

    private func lyricRow(_ item: NASLyricsBatchRunner.Item) -> some View {
        Button {
            guard !item.candidates.isEmpty, !lyricsRunner.isWriting else { return }
            ATMusicHaptics.tap()
            lyricPickerID = item.id
        } label: {
            HStack(spacing: 10) {
                icon(for: item.state)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.song.name)
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Text(itemSubtitle(item))
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(item.candidates.isEmpty ? Color.atmusicComment : Color.atmusicAmber.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !item.candidates.isEmpty, !lyricsRunner.isWriting {
                    Text("换")
                        .font(ATMusicFont.appFont(11, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                } else {
                    Text(item.state.title)
                        .font(ATMusicFont.appFont(10, .medium))
                        .foregroundStyle(item.state.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(item.candidates.isEmpty || lyricsRunner.isWriting)
    }

    private func itemSubtitle(_ item: NASLyricsBatchRunner.Item) -> String {
        if let selected = item.selectedCandidate {
            return "\(selected.provider) · 置信 \(selected.score) · 共 \(item.candidates.count) 个候选"
        }
        return item.detail.isEmpty ? item.song.artists : item.detail
    }

    // MARK: 封面列表

    @ViewBuilder
    private var coversSection: some View {
        if !coverRunner.targets.isEmpty {
            progressHeader(
                title: coverRunner.isWriting ? "正在写入封面…" : "匹配结果",
                done: coverRunner.isWriting ? coverRunner.writtenAlbumCount : coverRunner.targets.filter { $0.hasCover }.count,
                total: coverRunner.targets.count,
                detail: coverRunner.summary
            )
            LazyVStack(spacing: 6) {
                ForEach(coverRunner.targets) { target in
                    coverRow(target)
                }
            }
        }
    }

    private func coverRow(_ target: NASCoverBatchRunner.Target) -> some View {
        Button {
            guard !target.candidates.isEmpty, !coverRunner.isWriting else { return }
            ATMusicHaptics.tap()
            coverPickerID = target.id
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let thumb = target.selectedCandidate?.thumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                            .overlay {
                                Image(systemName: "questionmark")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.album.isEmpty ? "未知专辑" : target.album)
                        .font(ATMusicFont.appFont(12, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Text(targetSubtitle(target))
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(target.hasCover ? Color.atmusicAmber.opacity(0.9) : Color.atmusicComment)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                if target.hasCover, !coverRunner.isWriting {
                    Text("\(target.candidates.count) 张可选")
                        .font(ATMusicFont.appFont(10, .medium))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                } else {
                    Text(target.state.title)
                        .font(ATMusicFont.appFont(10, .medium))
                        .foregroundStyle(target.state.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(target.candidates.isEmpty ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(target.candidates.isEmpty || coverRunner.isWriting)
    }

    private func targetSubtitle(_ target: NASCoverBatchRunner.Target) -> String {
        let base = "\(target.artist) · \(target.songs.count) 首"
        if let selected = target.selectedCandidate {
            return base + " · \(selected.provider)"
        }
        return target.detail.isEmpty ? base : target.detail
    }

    // MARK: 进度头

    private func progressHeader(title: String, done: Int, total: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("\(done)/\(total)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.atmusicAmber)
            }
            ProgressView(value: Double(done), total: Double(max(1, total)))
                .tint(Color.atmusicAmber)
            if !detail.isEmpty {
                Text(detail)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    @ViewBuilder
    private func icon(for state: NASLyricsBatchRunner.ItemState) -> some View {
        switch state {
        case .pending, .checking, .matching, .writing:
            ProgressView().controlSize(.mini)
        case .matched:
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Color.atmusicAmber)
        case .written:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Color.atmusicComment)
        case .noMatch:
            Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.red.opacity(0.85))
        }
    }

    // MARK: 动作条

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 8) {
            if mode == .lyrics {
                if lyricsRunner.isMatching || lyricsRunner.isWriting {
                    GlassButton(title: "中止", systemName: "stop.circle") { lyricsRunner.cancel() }
                } else if lyricsRunner.items.isEmpty {
                    GlassButton(
                        title: isPreparingLibrary ? "正在读取曲库…" : matchButtonTitle,
                        systemName: "sparkle.magnifyingglass",
                        prominent: true
                    ) { startLyricsMatch() }
                    .disabled(isPreparingLibrary || !synology.isLoggedIn)
                    .opacity(isPreparingLibrary || !synology.isLoggedIn ? 0.5 : 1)
                } else {
                    GlassButton(
                        title: "写入 \(lyricsRunner.writeableCount) 首歌词",
                        systemName: "square.and.arrow.down.on.square",
                        prominent: true
                    ) { lyricsRunner.write() }
                    .disabled(lyricsRunner.writeableCount == 0)
                    .opacity(lyricsRunner.writeableCount == 0 ? 0.5 : 1)
                    GlassButton(title: "重新匹配", systemName: "arrow.clockwise") { lyricsRunner.reset() }
                }
            } else {
                if coverRunner.isMatching || coverRunner.isWriting {
                    GlassButton(title: "中止", systemName: "stop.circle") { coverRunner.cancel() }
                } else if coverRunner.targets.isEmpty {
                    GlassButton(
                        title: usingLibrary ? "先选择要补封面的歌曲" : "开始自动搜索封面",
                        systemName: "sparkle.magnifyingglass",
                        prominent: true
                    ) {
                        coverRunner.match(
                            songs: selectedSongs,
                            embedIntoFiles: embedIntoFiles,
                            writeFolderCover: writeFolderCoverFile
                        )
                    }
                    .disabled(usingLibrary || !synology.isLoggedIn || (!embedIntoFiles && !writeFolderCoverFile))
                    .opacity(usingLibrary || !synology.isLoggedIn ? 0.5 : 1)
                } else {
                    GlassButton(
                        title: "写入 \(coverRunner.includedCount) 张专辑封面（\(coverRunner.includedSongCount) 首）",
                        systemName: "square.and.arrow.down.on.square",
                        prominent: true
                    ) { coverRunner.write() }
                    .disabled(coverRunner.includedCount == 0)
                    .opacity(coverRunner.includedCount == 0 ? 0.5 : 1)
                    GlassButton(title: "重新匹配", systemName: "arrow.clockwise") { coverRunner.reset() }
                }
            }
        }
    }

    private var matchButtonTitle: String {
        usingLibrary ? "开始搜索匹配（上限 \(libraryLimit) 首）" : "开始搜索匹配（\(selectedSongs.count) 首）"
    }

    private var footerNote: some View {
        Text(mode == .lyrics
             ? "写回走 Audio Station 标签通道直接改原文件并回读确认；不可写格式会提前跳过。"
             : "封面内嵌走「下载 → 写标签 → 回传覆盖」，单文件超过 300 MB 会跳过内嵌、只用 cover.jpg 兜底。")
            .font(ATMusicFont.appFont(10))
            .foregroundStyle(Color.atmusicComment.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
    }

    // MARK: 动作

    private func startLyricsMatch() {
        guard !isPreparingLibrary else { return }
        message = ""
        if !usingLibrary {
            lyricsRunner.prepare(songs: selectedSongs.sorted(by: Self.playbackOrder), strategy: strategy)
            return
        }
        isPreparingLibrary = true
        Task {
            do {
                let songs = try await Self.loadLibrarySongs(maxCount: 2000)
                await MainActor.run {
                    isPreparingLibrary = false
                    guard !songs.isEmpty else {
                        message = "NAS 曲库为空，请先在群晖音乐库中确认歌曲索引。"
                        return
                    }
                    lyricsRunner.prepare(songs: Array(Self.prioritized(songs).prefix(libraryLimit)), strategy: strategy)
                }
            } catch {
                await MainActor.run {
                    isPreparingLibrary = false
                    message = "读取 NAS 曲库失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: 工具

    static func albumCount(_ songs: [Song]) -> Int {
        Set(songs.map(Self.albumKey)).count
    }

    static func albumKey(_ song: Song) -> String {
        let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (song.albumArtist?.isEmpty == false ? song.albumArtist! : song.artists)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(album)|\(artist)".lowercased()
    }

    static func playbackOrder(_ lhs: Song, _ rhs: Song) -> Bool {
        if lhs.album != rhs.album {
            return lhs.album.localizedStandardCompare(rhs.album) == .orderedAscending
        }
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
        if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    static func loadLibrarySongs(maxCount: Int) async throws -> [Song] {
        var collected: [Song] = []
        var offset = 0
        let pageSize = 500
        var seen = Set<String>()
        while collected.count < maxCount {
            let page = try await SynologyAPI.shared.songs(offset: offset, limit: pageSize)
            if page.isEmpty { break }
            var added = 0
            for song in page where seen.insert(song.identityKey).inserted {
                collected.append(song)
                added += 1
            }
            if page.count < pageSize || added == 0 { break }
            offset += page.count
        }
        return collected
    }

    static func prioritized(_ songs: [Song]) -> [Song] {
        songs.sorted { lhs, rhs in
            if (lhs.trackNumber > 0) != (rhs.trackNumber > 0) { return !(lhs.trackNumber > 0) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - 歌词流水线（匹配 → 手动挑候选 → 写入）

@MainActor
final class NASLyricsBatchRunner: ObservableObject {
    enum ItemState: String {
        case pending, checking, matching, matched, skipped, noMatch, writing, written, failed

        var title: String {
            switch self {
            case .pending: return "待匹配"
            case .checking: return "读取现有歌词"
            case .matching: return "匹配中"
            case .matched: return "待写入"
            case .skipped: return "跳过"
            case .noMatch: return "未匹配"
            case .writing: return "写入中"
            case .written: return "已写回"
            case .failed: return "失败"
            }
        }

        var color: Color {
            switch self {
            case .written: return .green
            case .failed: return .red
            case .noMatch: return .orange
            case .matched: return Color.atmusicAmber
            default: return Color.atmusicComment
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let song: Song
        var state: ItemState = .pending
        var detail: String = ""
        var candidates: [SongLyricsLoader.OnlineMatch] = []
        var selectedIndex: Int = 0

        var selectedCandidate: SongLyricsLoader.OnlineMatch? {
            guard candidates.indices.contains(selectedIndex) else { return candidates.first }
            return candidates[selectedIndex]
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isMatching = false
    @Published private(set) var isWriting = false
    @Published private(set) var summary: String = ""

    private var task: Task<Void, Never>?
    private var strategy: NASBatchMaintenanceSheet.LyricsStrategy = .missingOnly

    var isWorking: Bool { isMatching || isWriting }
    var matchedCount: Int { items.filter { !$0.candidates.isEmpty || $0.state == .written }.count }
    var writtenCount: Int { items.filter { $0.state == .written }.count }
    var writeableCount: Int { items.filter { $0.selectedCandidate != nil && $0.state != .written }.count }

    func item(id: String) -> Item? { items.first { $0.id == id } }

    func selectCandidate(_ index: Int, for id: String) {
        guard let position = items.firstIndex(where: { $0.id == id }),
              items[position].candidates.indices.contains(index) else { return }
        items[position].selectedIndex = index
    }

    func prepare(songs: [Song], strategy: NASBatchMaintenanceSheet.LyricsStrategy) {
        guard !isWorking else { return }
        self.strategy = strategy
        items = songs.map { Item(id: $0.identityKey, song: $0) }
        summary = ""
        isMatching = true
        task = Task { [weak self] in await self?.runMatching(overwriteAll: strategy == .overwriteAll) }
    }

    func write() {
        guard !isWorking else { return }
        guard writeableCount > 0 else { return }
        isWriting = true
        task = Task { [weak self] in await self?.runWriting() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isMatching = false
        isWriting = false
        summary = "已中止"
    }

    func reset() {
        task?.cancel()
        task = nil
        items = []
        summary = ""
        isMatching = false
        isWriting = false
    }

    private func update(_ id: String, state: ItemState, detail: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        if let detail { items[index].detail = detail }
    }

    private func runMatching(overwriteAll: Bool) async {
        var ready = 0
        var skipped = 0
        var unmatched = 0
        let writableExtensions: Set<String> = [
            "mp3", "mp2", "mpga",
            "m4a", "m4b", "mp4", "alac", "aac",
            "flac",
            "wav", "wave",
            "aiff", "aif", "aifc",
            "ogg", "oga", "opus",
            "ape",
            "dsf", "dff"
        ]

        for item in items {
            if Task.isCancelled { break }
            let song = item.song
            let ext = ((song.synologyPath ?? "") as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, writableExtensions.contains(ext) else {
                skipped += 1
                update(item.id, state: .skipped,
                       detail: ext.isEmpty ? "缺少原文件路径，无法写回" : "\(ext.uppercased()) 不支持写入歌词")
                continue
            }

            update(item.id, state: .checking)
            if !overwriteAll {
                let existing = (try? await SynologyAPI.shared.lyrics(song: song)) ?? ""
                if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    skipped += 1
                    update(item.id, state: .skipped, detail: "已有歌词，按策略跳过")
                    continue
                }
            }
            if Task.isCancelled { break }

            update(item.id, state: .matching)
            let candidates = await SongLyricsLoader.onlineLyricCandidates(for: song)
            if candidates.isEmpty {
                unmatched += 1
                update(item.id, state: .noMatch, detail: "没有可用的在线歌词")
                continue
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].candidates = candidates
                items[index].selectedIndex = 0
                items[index].state = .matched
                items[index].detail = "\(candidates[0].provider) · 置信 \(candidates[0].score)"
            }
            ready += 1
        }

        isMatching = false
        summary = "可写入 \(ready) 首 · 跳过 \(skipped) 首 · 未匹配 \(unmatched) 首"
        ATMusicLogger.shared.log("🎵 NAS 歌词匹配完成：\(summary)", level: .info)
    }

    private func runWriting() async {
        var written = 0
        var failed = 0
        let targets = items.filter { $0.selectedCandidate != nil && $0.state != .written }

        for item in targets {
            if Task.isCancelled { break }
            guard let candidate = item.selectedCandidate else { continue }
            update(item.id, state: .writing)
            do {
                let report = await LyricsPersistence.save(song: item.song, raw: candidate.lrc)
                guard report.isSuccess else {
                    throw SynologyError.networkError(report.message)
                }
                written += 1
                let lineCount = candidate.lrc.components(separatedBy: "\n").count
                let layers = [report.wroteFileTag ? "内嵌" : nil, report.wroteSidecar ? ".lrc" : nil]
                    .compactMap { $0 }.joined(separator: "+")
                update(item.id, state: .written, detail: "\(candidate.provider) · \(lineCount) 行 · \(layers)")
            } catch {
                failed += 1
                update(item.id, state: .failed, detail: error.localizedDescription)
                ATMusicLogger.shared.log("⚠️ NAS 歌词写回失败：\(item.song.name) - \(error.localizedDescription)", level: .error)
            }
        }

        let cancelled = Task.isCancelled
        isWriting = false
        summary = "写回 \(written) 首 · 失败 \(failed) 首" + (cancelled ? "（已中止）" : "")
        ATMusicLogger.shared.log("🎵 NAS 歌词批量写回结束：\(summary)", level: .info)
        if written > 0 {
            ToastCenter.shared.show("歌词写回完成：\(written) 首")
        }
        if written > 0, UserDefaults.standard.object(forKey: "atmusic.nas.index.autoAfterWrite") as? Bool ?? true {
            await NASIndexController.shared.start()
        }
    }
}

// MARK: - 封面流水线（匹配多候选 → 手动挑 → 内嵌 + cover.jpg）

@MainActor
final class NASCoverBatchRunner: ObservableObject {
    enum State: String {
        case pending, matching, matched, noMatch, writing, written, failed

        var title: String {
            switch self {
            case .pending: return "待匹配"
            case .matching: return "匹配中"
            case .matched: return "待写入"
            case .noMatch: return "未匹配"
            case .writing: return "写入中"
            case .written: return "已写入"
            case .failed: return "失败"
            }
        }

        var color: Color {
            switch self {
            case .written: return .green
            case .failed: return .red
            case .noMatch: return .orange
            case .matched: return Color.atmusicAmber
            default: return Color.atmusicComment
            }
        }
    }

    struct CoverCandidate: Identifiable {
        let id: String
        let url: URL
        let provider: String
        var data: Data?
        var thumbnail: UIImage?
    }

    struct Target: Identifiable {
        let id: String
        let album: String
        let artist: String
        let songs: [Song]
        var candidates: [CoverCandidate] = []
        var selectedIndex: Int = 0
        var state: State = .pending
        var detail: String = ""

        var selectedCandidate: CoverCandidate? {
            guard candidates.indices.contains(selectedIndex) else { return candidates.first }
            return candidates[selectedIndex]
        }

        var hasCover: Bool { selectedCandidate?.data != nil }
    }

    @Published private(set) var targets: [Target] = []
    @Published private(set) var isMatching = false
    @Published private(set) var isWriting = false
    @Published private(set) var summary: String = ""
    @Published private(set) var writtenAlbumCount: Int = 0

    private var task: Task<Void, Never>?
    private var embedIntoFiles = true
    private var writeFolderCover = true

    var isWorking: Bool { isMatching || isWriting }
    var includedCount: Int { targets.filter { $0.hasCover }.count }
    var includedSongCount: Int {
        targets.filter { $0.hasCover }.reduce(0) { $0 + $1.songs.count }
    }

    func target(id: String) -> Target? { targets.first { $0.id == id } }

    func selectCandidate(_ index: Int, for id: String) {
        guard let position = targets.firstIndex(where: { $0.id == id }),
              targets[position].candidates.indices.contains(index) else { return }
        targets[position].selectedIndex = index
        Task { await ensureCoverDataLoaded(targetID: id, index: index) }
    }

    func match(songs: [Song], embedIntoFiles: Bool, writeFolderCover: Bool) {
        guard !isWorking, !songs.isEmpty else { return }
        self.embedIntoFiles = embedIntoFiles
        self.writeFolderCover = writeFolderCover
        isMatching = true
        summary = ""
        targets = []
        task = Task { [weak self] in await self?.runMatching(songs: songs) }
    }

    func write() {
        guard !isWorking else { return }
        let group = targets.filter { $0.hasCover }
        guard !group.isEmpty else { return }
        isWriting = true
        writtenAlbumCount = 0
        task = Task { [weak self] in await self?.runWriting(group) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isMatching = false
        isWriting = false
        summary = "已中止"
    }

    func reset() {
        task?.cancel()
        task = nil
        targets = []
        summary = ""
        writtenAlbumCount = 0
        isMatching = false
        isWriting = false
    }

    // MARK: 匹配

    private func runMatching(songs: [Song]) async {
        let grouped = Dictionary(grouping: songs, by: NASBatchMaintenanceSheet.albumKey)
        var matched: [Target] = []

        for (key, groupSongs) in grouped {
            if Task.isCancelled { break }
            let sorted = groupSongs.sorted(by: NASBatchMaintenanceSheet.playbackOrder)
            guard let first = sorted.first else { continue }
            var target = Target(
                id: key,
                album: first.album,
                artist: first.albumArtist?.isEmpty == false ? first.albumArtist! : first.artists,
                songs: sorted
            )
            target.state = .matching

            let candidates = await SynologyAPI.shared.metadataCandidates(for: first)
            let normalizedAlbum = Self.normalize(first.album)
            let filtered = candidates.filter { $0.song.coverURL != nil }
            // 专辑名对得上的排前面，避免同名歌曲拿到别的封面
            let ranked = filtered.sorted { lhs, rhs in
                Self.albumScore(lhs.song.album, normalizedAlbum) > Self.albumScore(rhs.song.album, normalizedAlbum)
            }
            var coverCandidates: [CoverCandidate] = []
            for (index, candidate) in ranked.prefix(6).enumerated() {
                guard let url = candidate.song.coverURL else { continue }
                var entry = CoverCandidate(id: "\(key)#\(index)", url: url, provider: candidate.providerName)
                if index < 3, let data = await Self.downloadCover(url) {
                    let optimized = SynologyAPI.shared.optimizedCoverData(data)
                    entry.data = optimized
                    entry.thumbnail = UIImage(data: optimized)
                }
                coverCandidates.append(entry)
            }

            target.candidates = coverCandidates
            if coverCandidates.contains(where: { $0.data != nil }) {
                target.selectedIndex = coverCandidates.firstIndex(where: { $0.data != nil }) ?? 0
                target.state = .matched
                target.detail = "\(coverCandidates.count) 张候选"
            } else {
                target.state = .noMatch
                target.detail = "没有找到可用的专辑封面"
            }
            matched.append(target)
        }

        guard !Task.isCancelled else {
            isMatching = false
            return
        }
        isMatching = false
        targets = matched.sorted { $0.album.localizedStandardCompare($1.album) == .orderedAscending }
        let ready = targets.filter { $0.hasCover }.count
        summary = "共 \(targets.count) 张专辑 · 有封面候选 \(ready) 张 · 未匹配 \(targets.count - ready) 张"
        ATMusicLogger.shared.log("🖼 NAS 专辑封面匹配：\(summary)", level: .info)
    }

    private func ensureCoverDataLoaded(targetID: String, index: Int) async {
        guard let position = targets.firstIndex(where: { $0.id == targetID }),
              targets[position].candidates.indices.contains(index),
              targets[position].candidates[index].data == nil else { return }
        let url = targets[position].candidates[index].url
        guard let data = await Self.downloadCover(url) else { return }
        let optimized = SynologyAPI.shared.optimizedCoverData(data)
        guard let refreshed = targets.firstIndex(where: { $0.id == targetID }),
              targets[refreshed].candidates.indices.contains(index) else { return }
        targets[refreshed].candidates[index].data = optimized
        targets[refreshed].candidates[index].thumbnail = UIImage(data: optimized)
        if targets[refreshed].state == .noMatch { targets[refreshed].state = .matched }
    }

    // MARK: 写入

    private func runWriting(_ group: [Target]) async {
        var albums = 0
        var songsEmbedded = 0
        var folderCovers = 0
        var failedAlbums = 0
        var writtenFolderFolders = Set<String>()

        for target in group {
            if Task.isCancelled { break }
            guard let data = target.selectedCandidate?.data,
                  let index = targets.firstIndex(where: { $0.id == target.id }) else { continue }
            targets[index].state = .writing
            var embedded = 0
            var failed = 0

            if embedIntoFiles {
                for song in target.songs {
                    if Task.isCancelled { break }
                    do {
                        _ = try await SynologyAPI.shared.embedCoverIntoNASFile(song: song, coverData: data)
                        embedded += 1
                        songsEmbedded += 1
                    } catch {
                        failed += 1
                        ATMusicLogger.shared.log("⚠️ 封面内嵌失败：\(song.name) - \(error.localizedDescription)", level: .error)
                    }
                }
            }

            // 同目录同专辑：额外写一份 cover.jpg 兜底（一个目录只传一次）
            if writeFolderCover {
                let folders = Set(target.songs.compactMap { SynologyAPI.folderPath(of: $0) })
                if folders.count == 1, let folder = folders.first, !writtenFolderFolders.contains(folder) {
                    do {
                        try await SynologyAPI.shared.writeFolderCover(folderPath: folder, coverData: data)
                        writtenFolderFolders.insert(folder)
                        folderCovers += 1
                    } catch {
                        ATMusicLogger.shared.log("⚠️ cover.jpg 写入失败：\(folder) - \(error.localizedDescription)", level: .warn)
                    }
                }
            }

            if embedded > 0 || folderCovers > 0 {
                albums += 1
                targets[index].state = .written
                targets[index].detail = embedIntoFiles
                    ? "已内嵌 \(embedded)/\(target.songs.count) 首" + (failed > 0 ? " · 失败 \(failed)" : "")
                    : "已写 cover.jpg"
                writtenAlbumCount += 1
            } else {
                failedAlbums += 1
                targets[index].state = .failed
                targets[index].detail = "写入失败"
            }
        }

        let cancelled = Task.isCancelled
        isWriting = false
        summary = "封面：\(albums) 张专辑 · 内嵌 \(songsEmbedded) 首 · cover.jpg \(folderCovers) 个"
            + (failedAlbums > 0 ? " · 失败 \(failedAlbums) 张" : "")
            + (cancelled ? "（已中止）" : "")
        ATMusicLogger.shared.log("🖼 NAS 专辑封面写回结束：\(summary)", level: .info)

        SynologyAPI.shared.invalidateAllFolderCaches()
        SynologyAPI.shared.bumpLibraryIndexRevision()
        NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: nil)
        if albums > 0 { ToastCenter.shared.show("封面已写入 \(albums) 张专辑") }
        if songsEmbedded > 0, UserDefaults.standard.object(forKey: "atmusic.nas.index.autoAfterWrite") as? Bool ?? true {
            await NASIndexController.shared.start()
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func albumScore(_ candidate: String, _ target: String) -> Int {
        let value = normalize(candidate)
        guard !target.isEmpty, !value.isEmpty else { return 0 }
        if value == target { return 3 }
        if value.contains(target) || target.contains(value) { return 2 }
        return 1
    }

    private static func downloadCover(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return data
    }
}

// MARK: - 候选选择层

/// 歌词候选：列出同一首歌匹配到的多份歌词，点哪份用哪份。
struct NASLyricCandidateSheet: View {
    let title: String
    let subtitle: String
    let candidates: [SongLyricsLoader.OnlineMatch]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                        Button {
                            ATMusicHaptics.select()
                            onSelect(index)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(candidate.provider)
                                        .font(ATMusicFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Text("置信 \(candidate.score)")
                                        .font(ATMusicFont.appFont(10))
                                        .foregroundStyle(Color.atmusicComment)
                                    Spacer()
                                    if index == selectedIndex {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.atmusicAmber)
                                    }
                                }
                                Text(Self.preview(candidate.lrc))
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                                    .lineLimit(4)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                index == selectedIndex ? Color.atmusicAmber.opacity(0.12) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(ATMusicFont.appFont(14, .semibold))
                        Text(subtitle).font(ATMusicFont.appFont(10)).foregroundStyle(Color.atmusicComment)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
    }

    private static func preview(_ lrc: String) -> String {
        lrc.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(4)
            .joined(separator: "\n")
    }
}

/// 封面候选：网格展示同一张专辑搜到的多张封面，点哪张用哪张。
struct NASCoverCandidateSheet: View {
    let album: String
    let artist: String
    let candidates: [NASCoverBatchRunner.CoverCandidate]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                        Button {
                            ATMusicHaptics.select()
                            onSelect(index)
                        } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let thumb = candidate.thumbnail {
                                        Image(uiImage: thumb).resizable().scaledToFill()
                                    } else {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.primary.opacity(0.08))
                                            .overlay {
                                                ProgressView().controlSize(.small)
                                            }
                                    }
                                }
                                .frame(height: 120)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            index == selectedIndex ? Color.atmusicAmber : Color.clear,
                                            lineWidth: 2.5
                                        )
                                }
                                Text(candidate.provider)
                                    .font(ATMusicFont.appFont(10, .medium))
                                    .foregroundStyle(index == selectedIndex ? Color.atmusicAmber : Color.atmusicComment)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle(album.isEmpty ? "选择封面" : album)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(album.isEmpty ? "选择封面" : album).font(ATMusicFont.appFont(14, .semibold))
                        Text(artist).font(ATMusicFont.appFont(10)).foregroundStyle(Color.atmusicComment)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
    }
}

// MARK: - NAS 目录选择（含返回上一级）

struct NASFolderPickerSheet: View {
    struct Crumb: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var synology = SynologyAPI.shared
    let onConfirm: ([Song], String) -> Void

    @State private var stack: [Crumb] = [Crumb(id: "", name: "音乐库")]
    @State private var items: [SynologyFolderItem] = []
    @State private var isLoading = false
    @State private var isCollecting = false
    @State private var collectingText = ""
    @State private var selected: [String: Song] = [:]
    @State private var errorText = ""

    private var current: Crumb { stack.last ?? Crumb(id: "", name: "音乐库") }
    private var folders: [SynologyFolderItem] { items.filter { $0.kind == .folder } }
    private var songItems: [SynologyFolderItem] { items.filter { $0.kind == .song } }
    private var breadcrumbText: String { stack.map(\.name).joined(separator: " / ") }

    var body: some View {
        NavigationView {
            ZStack {
                Color.atmusicBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    navigationBar
                    if isLoading {
                        Spacer()
                        ProgressView("正在读取目录…")
                        Spacer()
                    } else if !errorText.isEmpty {
                        Spacer()
                        Text(errorText)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Spacer()
                    } else if items.isEmpty {
                        Spacer()
                        Text("这个目录里没有音频或子目录")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                        Spacer()
                    } else {
                        itemList
                    }
                    bottomBar
                }
            }
            .navigationTitle("选择 NAS 歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") { confirmSelection() }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
        .task(id: current.id) { await load(folderID: current.id) }
    }

    /// 面包屑 + 上一级 + 快捷动作：目录较深时这里是唯一的退路，不能只靠侧滑。
    private var navigationBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    goUp()
                } label: {
                    Label("上一级", systemImage: "chevron.up")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(stack.count > 1 ? Color.atmusicLabel : Color.atmusicComment.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(stack.count <= 1)

                Button {
                    ATMusicHaptics.tap()
                    Task { await load(folderID: current.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(7)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(stack.enumerated()), id: \.element.id) { index, crumb in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
                            }
                            Button {
                                ATMusicHaptics.tap()
                                stack = Array(stack.prefix(index + 1))
                            } label: {
                                Text(crumb.name)
                                    .font(ATMusicFont.appFont(12, index == stack.count - 1 ? .semibold : .regular))
                                    .foregroundStyle(index == stack.count - 1 ? Color.atmusicLabel : Color.atmusicComment)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Button {
                    ATMusicHaptics.select()
                    for item in songItems {
                        if let song = item.song { selected[song.identityKey] = song }
                    }
                } label: {
                    Label("全选本目录", systemImage: "checkmark.circle")
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(songItems.isEmpty)

                Button {
                    ATMusicHaptics.tap()
                    collectCurrentFolder()
                } label: {
                    Label(isCollecting ? "正在收集…" : "整目录加入", systemImage: "arrow.down.to.line")
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.atmusicAmber.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isCollecting)

                Spacer(minLength: 0)
                if !collectingText.isEmpty {
                    Text(collectingText)
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(folders) { folder in
                    Button {
                        ATMusicHaptics.tap()
                        stack.append(Crumb(id: folder.id, name: folder.name))
                    } label: {
                        row(icon: "folder.fill", title: folder.name, subtitle: "文件夹", isSelected: false)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(songItems) { item in
                    if let song = item.song {
                        Button {
                            ATMusicHaptics.select()
                            if selected.removeValue(forKey: song.identityKey) == nil {
                                selected[song.identityKey] = song
                            }
                        } label: {
                            row(
                                icon: selected[song.identityKey] == nil ? "circle" : "checkmark.circle.fill",
                                title: song.name,
                                subtitle: "\(song.artists) · \(song.album)",
                                isSelected: selected[song.identityKey] != nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func row(icon: String, title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(icon == "folder.fill" ? Color.atmusicAmber : (isSelected ? Color.atmusicAmber : Color.atmusicComment))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ATMusicFont.appFont(10))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if icon == "folder.fill" {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.atmusicAmber.opacity(0.12) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text(selected.isEmpty ? "尚未选择歌曲" : "已选 \(selected.count) 首")
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(selected.isEmpty ? Color.atmusicComment : Color.atmusicLabel)
                Spacer()
                if !selected.isEmpty {
                    Button {
                        ATMusicHaptics.tap()
                        selected.removeAll()
                    } label: {
                        Text("清空")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .buttonStyle(.plain)
                }
            }
            GlassButton(
                title: selected.isEmpty ? "请勾选歌曲或整目录加入" : "使用这 \(selected.count) 首",
                systemName: "checkmark",
                prominent: true
            ) {
                confirmSelection()
            }
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: 数据

    private func goUp() {
        guard stack.count > 1 else { return }
        ATMusicHaptics.tap()
        stack.removeLast()
    }

    private func confirmSelection() {
        let songs = selected.values.sorted(by: NASBatchMaintenanceSheet.playbackOrder)
        guard !songs.isEmpty else { return }
        onConfirm(songs, breadcrumbText + "（\(songs.count) 首）")
        dismiss()
    }

    private func load(folderID: String) async {
        isLoading = true
        errorText = ""
        do {
            items = try await loadAllItems(folderID: folderID)
        } catch {
            items = []
            errorText = "读取目录失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadAllItems(folderID: String) async throws -> [SynologyFolderItem] {
        var collected: [SynologyFolderItem] = []
        var offset = 0
        let pageSize = 200
        while collected.count < 3000 {
            let page = try await synology.folderItems(
                folderID: folderID.isEmpty ? nil : folderID,
                offset: offset,
                limit: pageSize
            )
            if page.isEmpty { break }
            collected.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += page.count
        }
        return collected
    }

    /// 递归收集当前目录（含子目录，最多 8 层、最多 5000 首）里的全部歌曲。
    private func collectCurrentFolder() {
        guard !isCollecting else { return }
        isCollecting = true
        collectingText = "准备中…"
        let startID = current.id
        Task {
            var found: [Song] = []
            var queue: [(id: String, depth: Int)] = [(startID, 0)]
            var visited = Set<String>()
            while !queue.isEmpty {
                let next = queue.removeFirst()
                guard next.depth <= 8, found.count < 5000 else { continue }
                guard visited.insert(next.id).inserted else { continue }
                guard let page = try? await loadAllItems(folderID: next.id) else { continue }
                for item in page {
                    if item.kind == .folder {
                        queue.append((item.id, next.depth + 1))
                    } else if let song = item.song {
                        found.append(song)
                    }
                }
                let count = found.count
                await MainActor.run { collectingText = "已找到 \(count) 首…" }
            }
            await MainActor.run {
                for song in found { selected[song.identityKey] = song }
                isCollecting = false
                collectingText = "整目录共 \(found.count) 首"
                ATMusicHaptics.success()
            }
        }
    }
}
