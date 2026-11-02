import SwiftUI
import UniformTypeIdentifiers

/// NAS 歌单内容编辑器：曲目增删 + 拖动重排 + 歌单改名/删除，一次性提交并回读校验。
///
/// 为什么做成"本地编辑 → 一次保存"而不是每步实时请求：
/// Audio Station 的 updatesongs 语义在各 DSM 版本上不统一，逐个操作各发一次请求，
/// 一旦某次语义不符，歌单就被改到一半；集中提交只需要一次校验与一次回滚。
struct NASPlaylistEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var synology = SynologyAPI.shared

    let playlist: Playlist
    /// nil 表示歌单已被删除
    var onChanged: ((Playlist?) -> Void)? = nil

    struct Row: Identifiable {
        let id: String
        let song: Song
    }

    @State private var rows: [Row] = []
    @State private var originalKeys: [String] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var message = ""
    @State private var draggingID: String?
    @State private var showSongPicker = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var name: String

    init(playlist: Playlist, onChanged: ((Playlist?) -> Void)? = nil) {
        self.playlist = playlist
        self.onChanged = onChanged
        _name = State(initialValue: playlist.name)
    }

    private var playlistID: String { playlist.synologyPlaylistId ?? "\(playlist.id)" }
    private var isDirty: Bool { rows.map { Self.key($0.song) } != originalKeys }

    var body: some View {
        NavigationView {
            ZStack {
                Color.atmusicBackground.ignoresSafeArea()
                if isLoading {
                    ProgressView("正在读取歌单…")
                } else {
                    VStack(spacing: 0) {
                        summaryCard
                        if !message.isEmpty {
                            Text(message)
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                        }
                        trackList
                        bottomBar
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        if isSaving { return }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            renameText = name
                            showRename = true
                        } label: {
                            Label("重命名歌单", systemImage: "character.cursor.ibeam")
                        }
                        Button {
                            deduplicateRows()
                        } label: {
                            Label("去除重复歌曲", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            Task { await exportRowsToLocal() }
                        } label: {
                            Label("导出为本地歌单", systemImage: "square.and.arrow.down")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("歌单操作")
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
        .task { await load() }
        .sheet(isPresented: $showSongPicker) {
            NASFolderPickerSheet { songs, _ in
                append(songs)
            }
            .environmentObject(theme)
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { await rename() } }
        }
        .confirmationDialog("删除这个 NAS 歌单？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除「\(name)」", role: .destructive) { Task { await deletePlaylist() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("歌单会从 Audio Station 中移除，里的歌曲文件本身不受影响。")
        }
    }

    // MARK: 子视图

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                Text("\(rows.count) 首")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                if isDirty {
                    Text("· 有未保存改动")
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(Color.atmusicAmber)
                }
                Spacer()
            }
            Text("按住右侧把手拖动调整播放顺序，点 × 移除曲目，右上角菜单可改名或删除歌单。")
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(rows) { row in
                    trackRow(row)
                        .onDrag {
                            draggingID = row.id
                            ATMusicHaptics.tap()
                            return NSItemProvider(object: row.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: NASPlaylistRowDropDelegate(
                                itemID: row.id,
                                rows: $rows,
                                draggingID: $draggingID
                            )
                        )
                }
                if rows.isEmpty {
                    Text("歌单还是空的，点下面「添加曲目」从 NAS 目录里挑歌。")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func trackRow(_ row: Row) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.song.name)
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text("\(row.song.artists) · \(row.song.album)")
                    .font(ATMusicFont.appFont(10))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                ATMusicHaptics.tap()
                withAnimation(.snappy(duration: 0.18)) {
                    rows.removeAll { $0.id == row.id }
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 \(row.song.name)")
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atmusicComment.opacity(0.55))
                .frame(width: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            GlassButton(title: "添加曲目", systemName: "plus.circle") {
                showSongPicker = true
            }
            .disabled(isSaving)
            GlassButton(
                title: isSaving ? "正在写入 NAS…" : "保存到 NAS 歌单",
                systemName: "square.and.arrow.down",
                prominent: true
            ) {
                Task { await save() }
            }
            .disabled(isSaving || !isDirty)
            .opacity(isSaving || !isDirty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    // MARK: 数据

    private static func key(_ song: Song) -> String {
        SynologyAPI.playlistSongKey(song)
    }

    private func makeRows(from songs: [Song]) -> [Row] {
        var counters: [String: Int] = [:]
        return songs.map { song in
            let base = Self.key(song)
            let occurrence = counters[base, default: 0]
            counters[base] = occurrence + 1
            return Row(id: "\(base)#\(occurrence)", song: song)
        }
    }

    private func append(_ songs: [Song]) {
        rows.append(contentsOf: makeRows(from: songs).map { row in
            // 追加时保证 id 不与现有行冲突
            let base = Self.key(row.song)
            var existing = rows.filter { Self.key($0.song) == base }.count
            var id = "\(base)#\(existing)"
            while rows.contains(where: { $0.id == id }) {
                existing += 1
                id = "\(base)#\(existing)"
            }
            return Row(id: id, song: row.song)
        })
        message = "已加入 \(songs.count) 首，记得保存"
    }

    /// 去重只动本地 rows（isDirty 会自动变脏），点保存才提交到 NAS，
    /// 不破坏编辑器“本地编辑、一次性提交”的规矩。
    private func deduplicateRows() {
        var seen = Set<String>()
        let unique = rows.filter { seen.insert(Self.key($0.song)).inserted }
        let removed = rows.count - unique.count
        if removed == 0 {
            message = "没有发现重复歌曲"
        } else {
            rows = unique
            message = "已去除 \(removed) 首重复，点保存提交到 NAS"
        }
    }

    private func exportRowsToLocal() async {
        let songs = rows.map(\.song)
        guard !songs.isEmpty else {
            message = "歌单是空的"
            return
        }
        let created = await PlaylistManagementService.shared.copyToLocal(songs: songs, named: "\(name)（本地）")
        message = "已导出为本地歌单「\(created.name)」"
    }

    private func load() async {
        isLoading = true
        let songs = (try? await synology.playlistSongs(playlistId: playlistID)) ?? []
        rows = makeRows(from: songs)
        originalKeys = rows.map { Self.key($0.song) }
        isLoading = false
        // 注意：这里**不做**写入自检——自检会在 NAS 上建/删一个临时歌单，
        // 打开编辑器就产生副作用是不可接受的，只在真正保存时探测一次。
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        message = "正在写入 NAS 歌单…"
        do {
            if let sample = rows.first?.song {
                try await synology.ensurePlaylistWriteSupport(sampleSong: sample)
            }
            try await synology.moveNASPlaylistSongs(playlistID: playlistID, reordered: rows.map(\.song))
            originalKeys = rows.map { Self.key($0.song) }
            isSaving = false
            message = "已保存到 NAS（\(rows.count) 首）"
            ATMusicHaptics.success()
            ToastCenter.shared.show("NAS 歌单已更新")
            synology.invalidateAllFolderCaches()
            onChanged?(Playlist(id: playlist.id, name: name, coverURL: playlist.coverURL,
                                trackCount: rows.count, source: .synology, synologyPlaylistId: playlistID))
        } catch {
            isSaving = false
            message = "保存失败：\(error.localizedDescription)"
            ATMusicLogger.shared.log("⚠️ NAS 歌单保存失败：\(playlist.name) - \(error.localizedDescription)", level: .error)
        }
    }

    private func rename() async {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await synology.renameNASPlaylist(id: playlistID, name: trimmed)
            name = trimmed
            message = "已重命名为「\(trimmed)」"
            ToastCenter.shared.show("歌单已重命名")
            synology.invalidateAllFolderCaches()
            onChanged?(Playlist(id: playlist.id, name: trimmed, coverURL: playlist.coverURL,
                                trackCount: rows.count, source: .synology, synologyPlaylistId: playlistID))
        } catch {
            message = "重命名失败：\(error.localizedDescription)"
        }
    }

    private func deletePlaylist() async {
        do {
            try await synology.deleteNASPlaylist(id: playlistID)
            ToastCenter.shared.show("歌单已删除")
            synology.invalidateAllFolderCaches()
            onChanged?(nil)
            dismiss()
        } catch {
            message = "删除失败：\(error.localizedDescription)"
        }
    }
}

/// 歌单行拖动重排（与批量编辑器同一套交互习惯）。
struct NASPlaylistRowDropDelegate: DropDelegate {
    let itemID: String
    @Binding var rows: [NASPlaylistEditorSheet.Row]
    @Binding var draggingID: String?

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != itemID,
              let from = rows.firstIndex(where: { $0.id == draggingID }),
              let to = rows.firstIndex(where: { $0.id == itemID }) else { return }
        withAnimation(.snappy(duration: 0.16)) {
            let moved = rows.remove(at: from)
            rows.insert(moved, at: to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        ATMusicHaptics.success()
        return true
    }
}

/// 通用单字段输入弹层（新建歌单这类只需要一个名字的场景）。
struct NASSingleFieldSheet: View {
    let title: String
    let placeholder: String
    let confirmTitle: String
    var initialText: String = ""
    let onSubmit: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSubmitting = false

    init(title: String, placeholder: String, confirmTitle: String, initialText: String = "",
         onSubmit: @escaping (String) async -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.onSubmit = onSubmit
        _text = State(initialValue: initialText)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                TextField(placeholder, text: $text)
                    .font(ATMusicFont.appFont(15))
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .autocorrectionDisabled()
                Spacer()
            }
            .padding(20)
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        guard !trimmed.isEmpty else { return }
                        isSubmitting = true
                        Task {
                            await onSubmit(trimmed)
                            await MainActor.run {
                                isSubmitting = false
                                dismiss()
                            }
                        }
                    }
                    .disabled(trimmed.isEmpty || isSubmitting)
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.height(240)], dragIndicator: true))
    }
}
