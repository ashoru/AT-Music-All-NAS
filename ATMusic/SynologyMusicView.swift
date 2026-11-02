import SwiftUI
import UIKit
import ImageIO

struct SynologyMusicView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var selectedTab: Int = 0 // 0: 歌曲, 1: 歌单
    @State private var searchText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showConfigSheet = false

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

            if !synology.isLoggedIn {
                notConnectedView
            } else if isLoading && songs.isEmpty && playlists.isEmpty {
                LoadingStateView()
            } else if let errorMessage, songs.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await loadData() }
                }
            } else {
                contentList
            }
        }
        .navigationTitle("群晖音乐库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfigSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
            }
        }
        .sheet(isPresented: $showConfigSheet) {
            SynologyLoginSheet()
                .environmentObject(theme)
        }
        .task {
            if synology.isLoggedIn {
                await loadData()
            }
        }
        .onChange(of: synology.libraryIndexRevision) { _ in
            guard synology.isLoggedIn else { return }
            Task { await loadData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSynologyMetadataDidUpdate)) { note in
            if let updated = note.object as? Song {
                for i in songs.indices {
                    let s = songs[i]
                    if s.identityKey == updated.identityKey || LocalLibraryStore.isMatchingSong(s, updated) || (s.source == updated.source && s.id == updated.id && s.id != 0) {
                        songs[i] = updated
                    }
                }
            }
        }
    }

    private var notConnectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 64))
                .foregroundStyle(Color.atmusicAmber)

            Text("尚未连接群晖 NAS")
                .font(ATMusicFont.appFont(18, .bold))
                .foregroundStyle(Color.atmusicLabel)

            Text("连接您的群晖 Audio Station 套件\n即可在 AT Music 中流畅播放您的私有高品质音乐")
                .font(ATMusicFont.appFont(13))
                .foregroundStyle(Color.atmusicComment)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button {
                showConfigSheet = true
            } label: {
                Text("配置群晖服务器")
                    .font(ATMusicFont.appFont(15, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.atmusicAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle())
        }
        .padding(32)
    }

    private var contentList: some View {
        List {
            headerSection
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if selectedTab == 0 {
                // 歌曲列表
                Section {
                    ForEach(Array(displayedSongs.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, glassRow: true, playbackContext: displayedSongs, playbackIndex: index, onTap: {
                            player.play(songs: displayedSongs, startAt: index)
                        })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } else {
                // 歌单列表
                Section {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .frame(width: 44, height: 44)
                                    .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .semibold))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Text("群晖云端歌单")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .refreshable {
            await loadData()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 60, height: 60)
                    .background(Color.atmusicAmber.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(synology.account.isEmpty ? "群晖 NAS" : "\(synology.account) 的 NAS")
                        .font(ATMusicFont.appFont(17, .bold))
                        .foregroundStyle(Color.atmusicLabel)

                    Text("\(songs.count) 首音乐 · \(playlists.count) 个歌单")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
            }

            if selectedTab == 0 && !displayedSongs.isEmpty {
                HStack(spacing: 10) {
                    GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                        player.play(songs: displayedSongs, startAt: 0)
                    }
                    GlassButton(title: "随机播放", systemName: "shuffle") {
                        if !displayedSongs.isEmpty {
                            let rnd = Int.random(in: 0..<displayedSongs.count)
                            player.play(songs: displayedSongs, startAt: rnd)
                        }
                    }
                }
            }

            // 搜索框与 Tab 切换
            VStack(spacing: 10) {
                Picker("", selection: $selectedTab) {
                    Text("全部歌曲 (\(songs.count))").tag(0)
                    Text("NAS 歌单 (\(playlists.count))").tag(1)
                }
                .pickerStyle(.segmented)

                if selectedTab == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.atmusicComment)
                        TextField("在群晖音乐库中搜索", text: $searchText)
                            .font(ATMusicFont.appFont(14))
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }

    private var displayedSongs: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kw.isEmpty {
            return songs
        }
        return songs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        do {
            async let fetchedSongs = synology.songs(offset: 0, limit: 1000)
            async let fetchedPlaylists = synology.allPlaylists()
            let (s, p) = try await (fetchedSongs, fetchedPlaylists)
            songs = s
            playlists = p
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

/// NAS 歌曲信息：先以半屏卡片展示，点某一个标签才进入对应的全屏编辑页。
/// 不会在打开时自动用在线结果覆盖任何已有字段。
struct SynologyMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    let song: Song
    var onUpdated: ((Song) -> Void)? = nil

    @State private var metadata: SynologyTagMetadata
    @State private var originalMetadata: SynologyTagMetadata
    @State private var selectedCoverURL: URL?
    @State private var selectedCoverData: Data?
    @State private var selectedCoverSource = ""
    @State private var editingField: SongMetadataField?
    @State private var showCoverSearch = false
    @State private var isSaving = false
    @State private var message = ""

    init(song: Song, onUpdated: ((Song) -> Void)? = nil) {
        self.song = song
        self.onUpdated = onUpdated
        let snapshot = SynologyTagMetadata(
            title: Self.editableValue(song.name, placeholders: ["", "未知歌曲"]),
            artist: Self.editableValue(song.artists, placeholders: ["", "未知艺术家"]),
            album: Self.editableValue(song.album, placeholders: ["", "群晖 NAS"]),
            albumArtist: song.albumArtist ?? "",
            genre: song.genre ?? "",
            year: song.year ?? "",
            track: song.trackNumber > 0 ? String(song.trackNumber) : "",
            disc: song.discNumber > 0 ? String(song.discNumber) : "",
            comment: song.comment ?? ""
        )
        _metadata = State(initialValue: snapshot)
        _originalMetadata = State(initialValue: snapshot)
    }

    private var displayedCoverURL: URL? { selectedCoverURL ?? song.coverURL }
    private var changedTagCount: Int {
        let patch = metadata.patch(comparedTo: originalMetadata)
        return [patch.title, patch.artist, patch.album, patch.albumArtist, patch.genre,
                patch.year, patch.comment, patch.track, patch.disc].compactMap { $0 }.count
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    songFileSummary
                    Divider().overlay(Color.atmusicSecondary.opacity(0.26))
                    tagRows
                    if !message.isEmpty {
                        Text(message)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                    }
                    actionButtons
                }
                .padding(.top, 10)
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle("歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .fullScreenCover(item: $editingField) { field in
            SongMetadataFieldEditor(field: field, initialValue: value(for: field)) { value in
                set(value, for: field)
            }
        }
        .fullScreenCover(isPresented: $showCoverSearch) {
            SongCoverSearchGridSheet(song: song) { candidate in
                selectedCoverURL = candidate.song.coverURL
                selectedCoverData = nil
                selectedCoverSource = candidate.providerName
            } onPickData: { data in
                selectedCoverData = data
                selectedCoverURL = nil
                selectedCoverSource = "本机图片"
            }
        }
    }

    private var songFileSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetadataStaticRow(title: "文件路径", value: song.synologyPath ?? "未读取到原文件路径", multiline: true)
            MetadataStaticRow(title: "来源", value: "群晖 NAS")
            MetadataStaticRow(title: "格式", value: fileExtension.isEmpty ? "音频文件" : fileExtension.uppercased())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var tagRows: some View {
        VStack(spacing: 0) {
            Button { showCoverSearch = true } label: {
                HStack(spacing: 16) {
                    Text("封面").foregroundStyle(Color.atmusicComment)
                    Spacer()
                    Group {
                        if let selectedCoverData, let image = UIImage(data: selectedCoverData) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            CoverImage(url: displayedCoverURL, size: 48, cornerRadius: 8)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Image(systemName: "pencil").foregroundStyle(Color.atmusicComment)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            if !selectedCoverSource.isEmpty {
                Text("待写入封面：\(selectedCoverSource)")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }
            ForEach(SongMetadataField.allCases) { field in
                Divider().padding(.leading, 20).overlay(Color.atmusicSecondary.opacity(0.26))
                Button { editingField = field } label: {
                    HStack(spacing: 14) {
                        Text(field.title).foregroundStyle(Color.atmusicComment)
                        Spacer(minLength: 16)
                        Text(value(for: field).isEmpty ? "未填写" : value(for: field))
                            .foregroundStyle(value(for: field).isEmpty ? Color.atmusicComment.opacity(0.7) : Color.atmusicLabel)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(field == .comment ? 2 : 1)
                        Image(systemName: "pencil").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.atmusicComment)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await save() }
            } label: {
                HStack {
                    if isSaving { ProgressView().tint(.white) }
                    Text(isSaving ? "写入中…" : changedTagCount == 0 && selectedCoverURL == nil && selectedCoverData == nil ? "没有待保存的改动" : "写入 NAS")
                }
                .font(ATMusicFont.appFont(16, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .foregroundStyle(Color.atmusicLabel)
            .background {
                ATMusicLiquidSelectionSurface(
                    shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    accent: .atmusicAmber
                )
            }
            .buttonStyle(.plain)
            .opacity(isSaving || (changedTagCount == 0 && selectedCoverURL == nil && selectedCoverData == nil) ? 0.55 : 1)
            .disabled(isSaving || (changedTagCount == 0 && selectedCoverURL == nil && selectedCoverData == nil))
            Button("取消") { dismiss() }
                .foregroundStyle(Color.atmusicLabel)
                .padding(.vertical, 8)
        }
        .padding(20)
    }

    private var fileExtension: String {
        ((song.synologyPath ?? "") as NSString).pathExtension
    }

    private func value(for field: SongMetadataField) -> String {
        switch field {
        case .title: return metadata.title
        case .artist: return metadata.artist
        case .album: return metadata.album
        case .albumArtist: return metadata.albumArtist
        case .genre: return metadata.genre
        case .year: return metadata.year
        case .trackNumber: return metadata.track
        case .discNumber: return metadata.disc
        case .comment: return metadata.comment
        }
    }

    private func set(_ value: String, for field: SongMetadataField) {
        switch field {
        case .title: metadata.title = value
        case .artist: metadata.artist = value
        case .album: metadata.album = value
        case .albumArtist: metadata.albumArtist = value
        case .genre: metadata.genre = value
        case .year: metadata.year = value
        case .trackNumber: metadata.track = value
        case .discNumber: metadata.disc = value
        case .comment: metadata.comment = value
        }
    }

    private func save() async {
        let patch = metadata.patch(comparedTo: originalMetadata)
        guard !patch.isEmpty || selectedCoverURL != nil || selectedCoverData != nil else { return }
        let wroteTags = !patch.isEmpty
        await MainActor.run { isSaving = true; message = "正在准备封面与元数据…" }

        var preparedCoverData = selectedCoverData
        var preparedCoverImage: UIImage? = selectedCoverData.flatMap { UIImage(data: $0) }
        if preparedCoverData == nil, let coverURL = selectedCoverURL {
            if coverURL.isFileURL {
                if let data = try? Data(contentsOf: coverURL), let img = UIImage(data: data) {
                    preparedCoverData = data
                    preparedCoverImage = img
                }
            } else {
                var req = URLRequest(url: coverURL)
                req.timeoutInterval = 12
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   !data.isEmpty, let img = UIImage(data: data) {
                    preparedCoverData = data
                    preparedCoverImage = img
                }
            }
        }

        await MainActor.run { message = "正在将已编辑字段写入 NAS…" }
        do {
            try await SynologyAPI.shared.applyMetadata(
                song: song,
                patch: patch,
                coverURL: selectedCoverURL,
                coverData: preparedCoverData
            )
            let refreshedCover = SynologyAPI.shared.coverURL(
                songId: song.synologyId ?? "\(song.id)",
                cacheBust: UUID().uuidString
            )
            let updatedSong = Song(
                id: song.id,
                name: metadata.title.isEmpty ? "未知歌曲" : metadata.title,
                artists: metadata.artist.isEmpty ? "未知艺术家" : metadata.artist,
                album: metadata.album.isEmpty ? "群晖 NAS" : metadata.album,
                coverURL: refreshedCover ?? song.coverURL,
                duration: song.duration,
                source: song.source,
                synologyId: song.synologyId,
                synologyServerScope: song.synologyServerScope,
                synologyPath: song.synologyPath,
                albumArtist: metadata.albumArtist.isEmpty ? nil : metadata.albumArtist,
                genre: metadata.genre.isEmpty ? nil : metadata.genre,
                year: metadata.year.isEmpty ? nil : metadata.year,
                comment: metadata.comment.isEmpty ? nil : metadata.comment,
                discNumber: max(1, TrackSequencing.parseNumber(metadata.disc, range: 1...999) ?? 1),
                trackNumber: TrackSequencing.parseNumber(metadata.track, range: 0...999) ?? 0,
                fee: song.fee
            )

            if let preparedCoverImage {
                if let refreshedCover {
                    ATMusicRemoteCoverCache.store(preparedCoverImage, for: refreshedCover)
                }
                if let oldCover = song.coverURL {
                    ATMusicRemoteCoverCache.store(preparedCoverImage, for: oldCover)
                }
                if let selectedCoverURL {
                    ATMusicRemoteCoverCache.store(preparedCoverImage, for: selectedCoverURL)
                }
            }

            await MainActor.run {
                player.replaceSong(updatedSong)
                DetailSongsCache.shared.updateSong(updatedSong)
                SynologyAPI.shared.updateCachedLibrarySong(updatedSong)
                onUpdated?(updatedSong)
                if let refreshedCover {
                    NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: refreshedCover)
                }
                if let oldCover = song.coverURL, oldCover != refreshedCover {
                    NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: oldCover)
                }
                NotificationCenter.default.post(name: .atmusicSongMetadataDidUpdate, object: updatedSong)
                NotificationCenter.default.post(name: .atmusicSynologyMetadataDidUpdate, object: updatedSong)
                SynologyAPI.shared.invalidateAllFolderCaches()
                SynologyAPI.shared.bumpLibraryIndexRevision()
            }
            await MainActor.run {
                originalMetadata = metadata
                selectedCoverURL = nil
                selectedCoverData = nil
                ToastCenter.shared.show(wroteTags ? "已写入修改的歌曲标签" : "已写入封面")
                dismiss()
            }
        } catch {
            await MainActor.run { message = "写入失败：\(error.localizedDescription)" }
        }
        await MainActor.run { isSaving = false }
    }

    private static func editableValue(_ value: String, placeholders: [String]) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return placeholders.contains(trimmed) ? "" : trimmed
    }
}

enum SongMetadataField: String, CaseIterable, Identifiable {
    case title, artist, album, albumArtist, genre, year, trackNumber, discNumber, comment
    var id: String { rawValue }
    var title: String {
        switch self {
        case .title: return "歌曲标题"
        case .artist: return "演出者"
        case .album: return "专辑名称"
        case .albumArtist: return "专辑演出者"
        case .genre: return "流派"
        case .year: return "专辑年份"
        case .trackNumber: return "音轨号"
        case .discNumber: return "盘号"
        case .comment: return "备注"
        }
    }
    var keyboard: UIKeyboardType {
        switch self {
        case .year, .trackNumber, .discNumber: return .numberPad
        default: return .default
        }
    }
    var multiline: Bool { self == .comment }

    /// 数字型标签的占位提示：避免用户把「音轨号」当成歌名之类的自由文本改。
    var placeholder: String {
        switch self {
        case .trackNumber: return "专辑内第几首，例如 3"
        case .discNumber: return "第几张 CD，单碟填 1"
        default: return "未填写"
        }
    }

    var isNumeric: Bool {
        switch self {
        case .trackNumber, .discNumber, .year: return true
        default: return false
        }
    }
}

struct MetadataStaticRow: View {
    let title: String
    let value: String
    var multiline = false
    var body: some View {
        HStack(alignment: multiline ? .top : .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(Color.atmusicComment).frame(width: 74, alignment: .leading)
            Text(value).foregroundStyle(Color.atmusicLabel).multilineTextAlignment(.leading).lineLimit(multiline ? 4 : 1)
            Spacer(minLength: 0)
        }
        .font(ATMusicFont.appFont(14))
    }
}

struct SongMetadataFieldEditor: View {
    @Environment(\.dismiss) private var dismiss
    let field: SongMetadataField
    @State private var value: String
    let onSave: (String) -> Void

    init(field: SongMetadataField, initialValue: String, onSave: @escaping (String) -> Void) {
        self.field = field
        _value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    /// 数字型标签只收数字：粘贴进来带空格/字母的内容也会被就地清洗，免得上游再兜底。
    private var numericBinding: Binding<String> {
        Binding(
            get: { value },
            set: { newValue in
                value = String(newValue.filter { $0.isNumber }.prefix(4))
            }
        )
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                Text("只会保存“\(field.title)”这一项，其他标签保持原样。")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicComment)
                if field.multiline {
                    TextEditor(text: $value)
                        .padding(10)
                        .frame(minHeight: 180)
                        .background(Color.atmusicCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    TextField(field.placeholder, text: field.isNumeric ? numericBinding : $value)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(field.keyboard)
                }
                Spacer()
            }
            .padding(20)
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle(field.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(value.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 封面独立使用全屏搜索网格；点击图片只选中封面，不会自动改动任何歌曲标签。
struct SongCoverSearchGridSheet: View {
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let onSelect: (SynologyMetadataCandidate) -> Void
    let onPickData: (Data) -> Void

    @State private var keyword: String
    @State private var candidates: [SynologyMetadataCandidate] = []
    @State private var isLoading = false
    @State private var showPhotoPicker = false

    init(song: Song, onSelect: @escaping (SynologyMetadataCandidate) -> Void, onPickData: @escaping (Data) -> Void) {
        self.song = song
        self.onSelect = onSelect
        self.onPickData = onPickData
        _keyword = State(initialValue: [song.artists, song.album, song.name].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private var covers: [SynologyMetadataCandidate] { candidates.filter { $0.song.coverURL != nil } }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("歌手、专辑或歌曲", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button("搜索") { Task { await search() } }
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background {
                            ATMusicLiquidSelectionSurface(shape: Capsule(), accent: .atmusicAmber)
                        }
                        .buttonStyle(.plain)
                }
                .padding(12)
                if isLoading { ProgressView("正在搜索在线封面…").padding(.bottom, 8) }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(covers) { candidate in
                            Button {
                                onSelect(candidate)
                                dismiss()
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    AsyncImage(url: candidate.song.coverURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color.atmusicCard.overlay(ProgressView()) }
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Spacer()
                                            CoverResolutionBadge(url: candidate.song.coverURL)
                                        }
                                    }
                                    .padding(6)

                                    VStack {
                                        Spacer()
                                        HStack {
                                            Text(candidate.providerName)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6).padding(.vertical, 4)
                                                .background(.black.opacity(0.58), in: Capsule())
                                            Spacer()
                                        }
                                    }
                                    .padding(6)
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                        Button { showPhotoPicker = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(Color.atmusicCard)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle("选择歌曲封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await search() }
            .sheet(isPresented: $showPhotoPicker) {
                WallpaperPhotoPicker { data in
                    onPickData(data)
                    showPhotoPicker = false
                    dismiss()
                }
            }
        }
    }

    private func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await MainActor.run { isLoading = true }
        let seed = Song(id: 0, name: trimmed, artists: "", album: "", coverURL: nil, duration: song.duration, source: .synology)
        let found = await SynologyAPI.shared.metadataCandidates(for: seed)
        await MainActor.run { candidates = found; isLoading = false }
    }
}

private struct CoverResolutionBadge: View {
    let url: URL?
    @State private var resolution: String?
    @State private var isLoading = false

    var body: some View {
        // 即使分辨率还没读完，也固定显示在右下角，避免用户误以为没有该信息。
        Text(resolution ?? (isLoading ? "读取中…" : "分辨率未知"))
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
            .task(id: url) {
                resolution = nil
                guard let url else {
                    isLoading = false
                    return
                }
                isLoading = true
                defer { isLoading = false }
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .returnCacheDataElseLoad
                    let (data, _) = try await URLSession.shared.data(for: request)
                    guard !Task.isCancelled, !data.isEmpty else { return }
                    if let source = CGImageSourceCreateWithData(data as CFData, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                       let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
                       pixelWidth > 0, pixelHeight > 0 {
                        resolution = "\(pixelWidth)×\(pixelHeight)"
                    } else if let image = UIImage(data: data) {
                        let scale = image.scale > 0 ? image.scale : 1
                        let width = Int((image.size.width * scale).rounded())
                        let height = Int((image.size.height * scale).rounded())
                        if width > 0 && height > 0 {
                            resolution = "\(width)×\(height)"
                        }
                    }
                } catch {
                    // 保留“分辨率未知”提示，不让角标消失。
                }
            }
    }
}

/// 主页/音乐库内嵌的 NAS 内容。它不使用 List，避免嵌套 ScrollView 时出现空白，
/// 同时不提供登录按钮，账号配置统一放在「我的 → 账号与登录」。
struct SynologyHomeSection: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var displayedSongs: [Song] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return songs }
        return songs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !synology.isLoggedIn {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("群晖 NAS 尚未连接")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("请前往“我的” → “账号与登录”配置群晖 Audio Station")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            } else if isLoading && songs.isEmpty && playlists.isEmpty {
                LoadingStateView()
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if let errorMessage, songs.isEmpty && playlists.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Color.atmusicAmber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("群晖音乐库")
                            .font(ATMusicFont.appFont(17, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("\(songs.count) 首音乐 · \(playlists.count) 个歌单")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    Spacer()
                    if !displayedSongs.isEmpty {
                        Button {
                            player.play(songs: displayedSongs, startAt: 0)
                        } label: {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(Color.atmusicAmber, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.atmusicComment)
                    TextField("在群晖音乐库中搜索", text: $searchText)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                if displayedSongs.isEmpty {
                    Text(searchText.isEmpty ? "群晖音乐库暂无歌曲" : "没有找到匹配的歌曲")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    SectionHeader(title: "歌曲")
                    ForEach(Array(displayedSongs.prefix(30).enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, glassRow: true, playbackContext: displayedSongs, playbackIndex: index, onTap: {
                            player.play(songs: displayedSongs, startAt: index)
                        })
                    }
                }

                if !playlists.isEmpty {
                    SectionHeader(title: "歌单")
                    ForEach(playlists.prefix(10)) { playlist in
                        NavigationLink {
                            PlaylistView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(Color.atmusicAmber)
                                Text(playlist.name)
                                    .font(ATMusicFont.appFont(14, .semibold))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text("\(playlist.trackCount) 首")
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(Color.atmusicComment)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            .padding(12)
                            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard synology.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let fetchedSongs = synology.songs(offset: 0, limit: 1000)
            async let fetchedPlaylists = synology.allPlaylists()
            let (newSongs, newPlaylists) = try await (fetchedSongs, fetchedPlaylists)
            songs = newSongs
            playlists = newPlaylists
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

/// NAS 首页：信息结构参考 Plexamp，控件保持 Apple Music 式原生排版。
struct SynologyAppleHomeSection: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var favorites = FavoritesStore.shared

    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var playlistPreviewSongs: [String: Song] = [:]
    @State private var todayRecommendations: [Song] = []
    @State private var recommendationsUpdatedAt = Date.distantPast
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedAlbum: Album?
    @State private var recentlyAddedAlbums: [Album] = []

    private var nasHistory: [Song] {
        player.history.filter { $0.source == .synology }
    }

    private var frequentArtistSongs: [Song] {
        let songs = nasHistory.isEmpty ? self.songs : nasHistory
        var seen = Set<String>()
        return songs.filter {
            let artist = $0.artists.trimmingCharacters(in: .whitespacesAndNewlines)
            return !artist.isEmpty && seen.insert(artist).inserted
        }.prefix(10).map { $0 }
    }

    private var frequentAlbums: [Song] {
        var seen = Set<String>()
        return (nasHistory.isEmpty ? songs : nasHistory).filter { seen.insert($0.album).inserted }.prefix(10).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !synology.isLoggedIn {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("群晖 NAS 尚未连接")
                        .font(ATMusicFont.appFont(16, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("请前往“我的” → “账号与登录”配置 Audio Station")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 45)
            } else if isLoading && songs.isEmpty {
                LoadingStateView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if let errorMessage, songs.isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                // 与 NAS 音乐软件的时间线习惯统一：推荐 → 最近添加 → 最近播放 → 收藏 → 歌单 → 专辑 / 歌手。
                synologySongSection(title: "今日推荐", songs: Array(todayRecommendations.prefix(12)), destination: SynologyRecommendationView(initialSongs: todayRecommendations))
                recentlyAddedSection
                synologySongSection(title: "最近播放", songs: Array(nasHistory.prefix(12)), destination: SynologySongCollectionView(title: "最近播放", songs: nasHistory))
                synologySongSection(title: "我最喜欢", songs: Array(favorites.synologyFavoriteSongs.prefix(12)), destination: SynologySongCollectionView(title: "我最喜欢", songs: favorites.synologyFavoriteSongs))
                synologyPlaylistSection
                synologyAlbumSection
                synologyArtistSection
            }
        }
        .task {
            if synology.isLoggedIn { await load() }
        }
        .sheet(item: $selectedAlbum) { album in
            ATMusicNavigationStack {
                SynologyAlbumView(
                    albumName: album.name,
                    artistName: album.artistName,
                    coverURL: album.coverURL,
                    initialSongs: songs.filter { $0.album == album.name }
                )
            }
            .environmentObject(player)
        }
    }

    @ViewBuilder
    private func synologySongSection<Destination: View>(title: String, songs: [Song], destination: Destination) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                synologySectionHeader(title: title, destination: destination)
                GeometryReader { proxy in
                    let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                                Button {
                                    player.play(songs: songs, startAt: index)
                                } label: {
                                    MediaSquareCard(title: song.name, subtitle: song.artists, coverURL: song.coverURL, showSourceBadge: false)
                                }
                                .frame(width: cardWidth)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(height: 212)
            }
        }
    }

    private var recentlyAddedSection: some View {
        Group {
            if !recentlyAddedAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    synologySectionHeader(title: "最近添加", destination: SynologyRecentAlbumsView(albums: recentlyAddedAlbums, songs: songs))
                    GeometryReader { proxy in
                        let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(recentlyAddedAlbums.prefix(12)) { album in
                                    Button {
                                        selectedAlbum = album
                                    } label: {
                                        MediaSquareCard(title: album.name, subtitle: album.artistName, coverURL: album.coverURL, showSourceBadge: false)
                                    }
                                    .frame(width: cardWidth)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(height: 212)
                }
            }
        }
    }

    private var synologyAlbumSection: some View {
        Group {
            if !frequentAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    synologySectionHeader(title: "常听专辑", destination: SynologyAlbumCollectionView(songs: songs))
                    GeometryReader { proxy in
                        let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(frequentAlbums) { song in
                                    Button {
                                        selectedAlbum = Album(
                                            id: "synology-album-\(SynologyAPI.stableID(song.album + song.artists))",
                                            name: song.album,
                                            artistName: song.artists,
                                            coverURL: song.coverURL,
                                            source: .synology
                                        )
                                    } label: {
                                        MediaSquareCard(title: song.album, subtitle: song.artists, coverURL: song.coverURL, showSourceBadge: false)
                                    }
                                    .frame(width: cardWidth)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(height: 212)
                }
            }
        }
    }

    private var synologyArtistSection: some View {
        Group {
            if !frequentArtistSongs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    synologySectionHeader(title: "常听歌手", destination: SynologyArtistCollectionView(songs: songs))
                    GeometryReader { proxy in
                        let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(frequentArtistSongs) { song in
                                    NavigationLink {
                                        SynologyArtistView(artistName: song.artists, coverURL: song.coverURL, initialSongs: self.songs)
                                    } label: {
                                        MediaSquareCard(title: song.artists, subtitle: "歌手", coverURL: song.coverURL, showSourceBadge: false, circularCover: true)
                                    }
                                    .frame(width: cardWidth)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(height: 212)
                }
            }
        }
    }

    private var synologyPlaylistSection: some View {
        Group {
            if !playlists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    synologySectionHeader(title: "歌单", destination: SynologyPlaylistCollectionView(playlists: playlists))
                    GeometryReader { proxy in
                        let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(playlists.prefix(8)) { playlist in
                            NavigationLink { PlaylistView(playlist: playlist) } label: {
                                let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                                MediaSquareCard(
                                    title: playlist.name,
                                    subtitle: "\(playlist.trackCount) 首",
                                    coverURL: playlistPreviewSongs[playlistID]?.coverURL ?? playlist.coverURL,
                                    showSourceBadge: false
                                )
                            }
                            .frame(width: cardWidth)
                            .buttonStyle(.plain)
                        }
                            }
                        }
                    }
                    .frame(height: 212)
                }
            }
        }
    }

    private func synologySectionHeader<Destination: View>(title: String, destination: Destination) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(ATMusicFont.appFont(20, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()
            NavigationLink {
                destination
            } label: {
                HStack(spacing: 4) {
                    Text("查看全部")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicComment)
            }
            .buttonStyle(.plain)
        }
    }

    private func load() async {
        guard synology.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            // 首页只先取一批足够首屏展示的歌曲；完整库随后静默补齐，
            // 避免大 NAS 曲库把“主页可见时间”绑在 1000 首歌曲请求上。
            async let initialSongs = synology.songs(offset: 0, limit: 240)
            async let fetchedPlaylists = synology.allPlaylists()
            async let fetchedRecentAlbums = synology.recentlyAddedAlbums()
            let loadedSongs = try await initialSongs
            let loadedPlaylists = try await fetchedPlaylists

            songs = loadedSongs
            playlists = loadedPlaylists
            recentlyAddedAlbums = await fetchedRecentAlbums
            if todayRecommendations.isEmpty || Date().timeIntervalSince(recommendationsUpdatedAt) >= 3600 {
                todayRecommendations = SynologyAPI.hourlyRecommendedSongs(from: loadedSongs, count: 20)
                recommendationsUpdatedAt = Date()
            }
            isLoading = false

            // 封面预览属于增强信息，不阻塞首屏。
            var previews: [String: Song] = [:]
            await withTaskGroup(of: (String, Song?).self) { group in
                for playlist in loadedPlaylists.prefix(8) {
                    let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                    group.addTask {
                        let song = (try? await synology.playlistSongs(playlistId: playlistID, limit: 1))?.first
                        return (playlistID, song)
                    }
                }
                for await (playlistID, song) in group {
                    if let song { previews[playlistID] = song }
                }
            }
            playlistPreviewSongs = previews

            // 完整库静默补齐，用于常听专辑/歌手及进入集合页后的完整内容。
            if let fullLibrary = try? await synology.songs(offset: 0, limit: 1000),
               fullLibrary.count > loadedSongs.count {
                songs = fullLibrary
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func songsForAlbum(_ album: Song) -> [Song] {
        songs.filter { $0.album == album.album && $0.artists == album.artists }
    }
}

struct SynologySongCollectionView: View {
    @EnvironmentObject private var player: PlayerManager
    let title: String
    let songs: [Song]

    var body: some View {
        List {
            if !songs.isEmpty {
                Button {
                    ATMusicHaptics.tap()
                    player.play(songs: songs, startAt: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index, onTap: {
                    player.play(songs: songs, startAt: index)
                })
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 今日推荐独立页面：保持当前推荐十分钟，支持右上角手动换一批。
struct SynologyRecommendationView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let initialSongs: [Song]
    @State private var songs: [Song]
    @State private var updatedAt = Date.distantPast
    @State private var isRefreshing = false
    @State private var refreshGeneration = 0

    init(initialSongs: [Song]) {
        self.initialSongs = initialSongs
        _songs = State(initialValue: initialSongs)
    }

    var body: some View {
        List {
            if !songs.isEmpty {
                Button {
                    ATMusicHaptics.tap()
                    player.play(songs: songs, startAt: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index, onTap: {
                    player.play(songs: songs, startAt: index)
                })
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if isRefreshing && songs.isEmpty { LoadingStateView() }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("今日推荐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .task {
            await refresh(force: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 600_000_000_000)
                    await refresh(force: true)
                } catch {
                    break
                }
            }
        }
    }

    private func refresh(force: Bool) async {
        guard synology.isLoggedIn else { return }
        guard force || songs.isEmpty || Date().timeIntervalSince(updatedAt) >= 600 else { return }

        await MainActor.run { isRefreshing = true }
        defer { Task { @MainActor in isRefreshing = false } }

        // 先立即换一批，点击按钮时不会因为 NAS 网络请求而看起来“没反应”。
        if force, !songs.isEmpty {
            let immediateSongs = Array(songs.shuffled().prefix(20))
            await MainActor.run {
                songs = immediateSongs
                updatedAt = Date()
                refreshGeneration += 1
            }
        }

        // 手动刷新跳过十分钟缓存，后台拿最新目录后再更新一次推荐。
        guard let library = try? await synology.librarySongs(forceRefresh: force), !library.isEmpty else { return }
        let refreshedSongs = Array(library.shuffled().prefix(20))
        await MainActor.run {
            songs = refreshedSongs
            updatedAt = Date()
            refreshGeneration += 1
        }
    }
}

/// 歌单全部页面：用 Apple Music 风格的封面列表和顶部搜索栏展示。
struct SynologyPlaylistCollectionView: View {
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var playlists: [Playlist]
    @State private var previewSongs: [String: Song] = [:]
    @State private var query = ""
    @State private var showCreate = false
    @State private var createName = ""
    @State private var editingPlaylist: Playlist?
    @State private var pendingDelete: Playlist?
    @State private var isMutating = false
    @State private var message = ""

    init(playlists: [Playlist]) {
        _playlists = State(initialValue: playlists)
    }

    private var filteredPlaylists: [Playlist] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var deleteDialogTitle: String {
        if let pendingDelete { return "删除「\(pendingDelete.name)」？" }
        return "删除歌单？"
    }

    private var createRow: some View {
        Button {
            ATMusicHaptics.tap()
            createName = ""
            showCreate = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 44, height: 44)
                    .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("新建 NAS 歌单")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("在 Audio Station 里创建，可在 App 内增删曲目与排序")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
            }
            .padding(10)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var messageRow: some View {
        Text(message)
            .font(ATMusicFont.appFont(11))
            .foregroundStyle(Color.atmusicComment)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
        return NavigationLink { PlaylistView(playlist: playlist) } label: {
            SynologyLibraryRow(
                coverURL: previewSongs[playlistID]?.coverURL ?? playlist.coverURL,
                title: playlist.name,
                subtitle: "\(playlist.trackCount) 首",
                systemImage: "music.note.list"
            )
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = playlist
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                editingPlaylist = playlist
            } label: {
                Label("管理", systemImage: "slider.horizontal.3")
            }
            .tint(Color.atmusicAmber)
        }
        .contextMenu {
            Button {
                editingPlaylist = playlist
            } label: {
                Label("管理曲目与名称", systemImage: "slider.horizontal.3")
            }
            Button(role: .destructive) {
                pendingDelete = playlist
            } label: {
                Label("删除歌单", systemImage: "trash")
            }
        }
    }

    private func applyEditorResult(_ updated: Playlist?, for original: Playlist) {
        guard let updated else {
            playlists.removeAll { $0.id == original.id }
            return
        }
        if let index = playlists.firstIndex(where: { $0.id == original.id }) {
            playlists[index] = updated
        }
    }

    var body: some View {
        List {
            Section {
                createRow
            }
            if !message.isEmpty {
                messageRow
            }
            ForEach(filteredPlaylists) { playlist in
                playlistRow(playlist)
            }
        }
        .sheet(isPresented: $showCreate) {
            NASSingleFieldSheet(
                title: "新建 NAS 歌单",
                placeholder: "歌单名称",
                confirmTitle: "创建",
                initialText: ""
            ) { name in
                await createPlaylist(named: name)
            }
        }
        .sheet(item: $editingPlaylist) { playlist in
            NASPlaylistEditorSheet(playlist: playlist) { updated in
                applyEditorResult(updated, for: playlist)
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = pendingDelete { Task { await deletePlaylist(target) } }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("歌单会从 Audio Station 移除，歌曲文件本身不受影响。")
        }
        .overlay {
            if playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.atmusicComment)
                    Text("暂无歌单")
                        .font(ATMusicFont.appFont(14))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索歌单")
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPreviews() }
    }

    private func createPlaylist(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isMutating = true
        do {
            let created = try await synology.createNASPlaylist(name: trimmed)
            if let created {
                playlists.append(created)
                message = "已创建「\(trimmed)」，点进去即可添加曲目"
            }
            ToastCenter.shared.show("NAS 歌单已创建")
            synology.invalidateAllFolderCaches()
        } catch {
            message = "创建失败：\(error.localizedDescription)"
        }
        isMutating = false
    }

    private func deletePlaylist(_ playlist: Playlist) async {
        isMutating = true
        let id = playlist.synologyPlaylistId ?? "\(playlist.id)"
        do {
            try await synology.deleteNASPlaylist(id: id)
            playlists.removeAll { $0.id == playlist.id }
            previewSongs.removeValue(forKey: id)
            message = "已删除「\(playlist.name)」"
            ToastCenter.shared.show("歌单已删除")
            synology.invalidateAllFolderCaches()
        } catch {
            message = "删除失败：\(error.localizedDescription)"
        }
        isMutating = false
    }

    private func loadPreviews() async {
        guard synology.isLoggedIn else { return }
        await withTaskGroup(of: (String, Song?).self) { group in
            for playlist in playlists {
                let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                group.addTask {
                    (playlistID, (try? await synology.playlistSongs(playlistId: playlistID, limit: 1))?.first)
                }
            }
            for await (playlistID, song) in group {
                if let song { previewSongs[playlistID] = song }
            }
        }
    }
}

/// 常听专辑全部页面：封面、专辑名、歌手和歌曲数保持统一行式排版。
struct SynologyAlbumCollectionView: View {
    let songs: [Song]
    @EnvironmentObject private var player: PlayerManager
    @State private var query = ""

    private var albums: [Song] {
        var seen = Set<String>()
        let unique = songs.filter { seen.insert("\($0.album)|\($0.artists)").inserted && !$0.album.isEmpty }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return unique }
        return unique.filter { $0.album.localizedCaseInsensitiveContains(keyword) || $0.artists.localizedCaseInsensitiveContains(keyword) }
    }

    @State private var selectedAlbum: Song?

    var body: some View {
        List {
            ForEach(albums) { album in
                Button {
                    selectedAlbum = album
                } label: {
                    SynologyLibraryRow(
                        coverURL: album.coverURL,
                        title: album.album,
                        subtitle: album.artists,
                        systemImage: "square.stack"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $selectedAlbum) { item in
            ATMusicNavigationStack {
                SynologyAlbumView(
                    albumName: item.album,
                    artistName: item.artists,
                    coverURL: item.coverURL,
                    initialSongs: songs.filter { $0.album == item.album }
                )
            }
            .environmentObject(player)
        }
        .overlay {
            if albums.isEmpty {
                Text("暂无专辑")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索专辑")
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("常听专辑")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 最近添加全部页面：顺序即 Audio Station 索引的入库时间倒序，不再二次排序。
struct SynologyRecentAlbumsView: View {
    let albums: [Album]
    let songs: [Song]
    @EnvironmentObject private var player: PlayerManager
    @State private var query = ""
    @State private var selectedAlbum: Album?

    private var filteredAlbums: [Album] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return albums }
        return albums.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) || $0.artistName.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        List {
            ForEach(filteredAlbums) { album in
                Button {
                    selectedAlbum = album
                } label: {
                    SynologyLibraryRow(
                        coverURL: album.coverURL ?? songs.first { $0.album == album.name }?.coverURL,
                        title: album.name,
                        subtitle: album.artistName,
                        systemImage: "square.stack"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $selectedAlbum) { album in
            ATMusicNavigationStack {
                SynologyAlbumView(
                    albumName: album.name,
                    artistName: album.artistName,
                    coverURL: album.coverURL,
                    initialSongs: songs.filter { $0.album == album.name }
                )
            }
            .environmentObject(player)
        }
        .overlay {
            if filteredAlbums.isEmpty {
                Text("暂无专辑")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索专辑")
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("最近添加")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 常听歌手全部页面：圆形头像列表，点击进入歌手详情。
struct SynologyArtistCollectionView: View {
    let songs: [Song]
    @State private var query = ""

    private var artists: [(name: String, song: Song)] {
        var seen = Set<String>()
        var result: [(name: String, song: Song)] = []
        for song in songs {
            for name in song.artists.components(separatedBy: " / ") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                result.append((trimmed, song))
            }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        List {
            ForEach(artists, id: \.name) { artist in
                NavigationLink {
                    SynologyArtistView(artistName: artist.name, coverURL: artist.song.coverURL, initialSongs: songs)
                } label: {
                    SynologyLibraryRow(
                        coverURL: artist.song.coverURL,
                        title: artist.name,
                        subtitle: "歌手",
                        circular: true,
                        systemImage: "person.crop.circle"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if artists.isEmpty {
                Text("暂无歌手")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索歌手")
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("常听歌手")
        .navigationBarTitleDisplayMode(.inline)
    }
}


private struct SynologyLibraryRow: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    var circular = false
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CoverImage(url: coverURL, size: 46, cornerRadius: circular ? 23 : 10)
                if coverURL == nil {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(7)
                        .background { ATMusicGlass(shape: Circle()) }
                        .offset(x: 3, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ATMusicFont.appFont(15, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atmusicComment)
        }
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.atmusicComment.opacity(0.18))
                .frame(height: 0.5)
                .padding(.leading, 58)
        }
    }
}

private enum SynologyLibraryCategory: String, CaseIterable, Identifiable {
    case playlists = "歌单"
    case folders = "文件夹"
    case artists = "歌手"

    var id: String { rawValue }
}

/// DS audio 风格的 NAS 音乐库入口：分类保留，默认从文件夹开始浏览。
struct SynologyLibrarySection: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var category: SynologyLibraryCategory = .folders
    @State private var folderItems: [SynologyFolderItem] = []
    @State private var folderPreviewSongs: [String: Song] = [:]
    /// 根目录各文件夹概要（含歌/子文件夹 + 封面预览歌），用于隐藏无音乐文件夹与取封面。
    @State private var folderOverviewCache: [String: SynologyFolderOverview] = [:]
    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var playlistPreviewSongs: [String: Song] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(categoryRaw: String = "文件夹") {
        _category = State(initialValue: SynologyLibraryCategory(rawValue: categoryRaw) ?? .folders)
    }

    private var albums: [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert("\($0.album)|\($0.artists)").inserted }
    }

    private var artists: [(name: String, coverURL: URL?)] {
        var seen = Set<String>()
        return songs.flatMap { song in
            song.artists.components(separatedBy: " / ").map { (name: $0, coverURL: song.coverURL) }
        }.filter {
            !$0.name.isEmpty && seen.insert($0.name).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !synology.isLoggedIn {
                Text("请前往“我的” → “账号与登录”连接群晖 NAS")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            } else {
                Picker("音乐库", selection: $category) {
                    ForEach(SynologyLibraryCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                if isLoading && songs.isEmpty && folderItems.isEmpty && playlists.isEmpty {
                    LoadingStateView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let errorMessage, songs.isEmpty && folderItems.isEmpty && playlists.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                } else {
                    categoryContent
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
                case .folders:
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "音乐文件夹")
                ForEach(folderItems) { item in
                    if item.kind == .folder {
                        // 隐藏十级子文件夹内无支持音频文件的文件夹：无概要先显示，概要回来后收起。
                        if let ov = folderOverviewCache[item.id] {
                            if ov.hasSupportedAudio {
                                rootFolderLink(item)
                            }
                        } else {
                            rootFolderLink(item)
                        }
                    } else if let song = item.song {
                        SongCell(song: song, glassRow: false, onTap: {
                            player.play(songs: [song])
                        })
                    }
                }
                if folderItems.isEmpty {
                    Text("根目录没有可显示的文件夹")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
        case .playlists:
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "歌单")
                ForEach(playlists) { playlist in
                    NavigationLink { PlaylistView(playlist: playlist) } label: {
                        let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                        SynologyLibraryRow(
                            coverURL: playlistPreviewSongs[playlistID]?.coverURL ?? playlist.coverURL,
                            title: playlist.name,
                            subtitle: "\(playlist.trackCount) 首",
                            systemImage: "music.note.list"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .artists:
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "歌手")
                ForEach(artists, id: \.name) { artist in
                    NavigationLink {
                        SynologyArtistView(artistName: artist.name, coverURL: artist.coverURL, initialSongs: songs)
                    } label: {
                        SynologyLibraryRow(
                            coverURL: artist.coverURL,
                            title: artist.name,
                            subtitle: "歌手",
                            circular: true,
                            systemImage: "person.crop.circle"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func rootFolderLink(_ item: SynologyFolderItem) -> some View {
        NavigationLink {
            SynologyFolderView(
                folderID: item.id,
                title: item.name,
                breadcrumbs: ["NAS", item.name]
            )
        } label: {
            SynologyLibraryRow(
                coverURL: folderOverviewCache[item.id]?.previewSong?.coverURL,
                title: item.name,
                subtitle: "文件夹",
                systemImage: "folder.fill"
            )
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard synology.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let root = synology.folderItems(limit: 200)
            async let allSongs = synology.songs(offset: 0, limit: 1000)
            async let loadedPlaylists = synology.allPlaylists()
            let (newRoot, newSongs, newPlaylists) = try await (root, allSongs, loadedPlaylists)
            folderItems = newRoot
            songs = newSongs
            playlists = newPlaylists
            var overviews: [String: SynologyFolderOverview] = [:]
            var uncachedFolders: [SynologyFolderItem] = []
            for item in newRoot where item.kind == .folder {
                if let cached = synology.cachedFolderOverview(folderID: item.id, folderPath: item.path) {
                    overviews[item.id] = cached
                } else {
                    uncachedFolders.append(item)
                }
            }
            folderOverviewCache = overviews

            if !uncachedFolders.isEmpty {
                await withTaskGroup(of: (String, SynologyFolderOverview).self) { group in
                    let concurrency = 3
                    var cursor = 0
                    while cursor < min(concurrency, uncachedFolders.count) {
                        let item = uncachedFolders[cursor]
                        cursor += 1
                        group.addTask {
                            (item.id, await synology.folderOverview(folderID: item.id, folderPath: item.path))
                        }
                    }
                    for await (folderID, ov) in group {
                        overviews[folderID] = ov
                        if cursor < uncachedFolders.count {
                            let next = uncachedFolders[cursor]
                            cursor += 1
                            group.addTask {
                                (next.id, await synology.folderOverview(folderID: next.id, folderPath: next.path))
                            }
                        }
                    }
                }
                folderOverviewCache = overviews
            }
            var playlistPreviews: [String: Song] = [:]
            await withTaskGroup(of: (String, Song?).self) { group in
                for playlist in newPlaylists {
                    let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                    group.addTask {
                        (playlistID, (try? await synology.playlistSongs(playlistId: playlistID, limit: 1))?.first)
                    }
                }
                for await (playlistID, song) in group {
                    if let song { playlistPreviews[playlistID] = song }
                }
            }
            playlistPreviewSongs = playlistPreviews
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

struct SynologyFolderView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let folderID: String?
    let title: String
    let breadcrumbs: [String]
    @State private var items: [SynologyFolderItem] = []
    @State private var displayedFolders: [SynologyFolderItem] = []
    @State private var displayedSongs: [Song] = []
    @State private var renderLimit: Int = 100

    private var visibleSongs: [Song] {
        let count = min(renderLimit, displayedSongs.count)
        guard count > 0 else { return [] }
        return Array(displayedSongs.prefix(count))
    }

    private func loadMoreSongsIfNeeded(at index: Int) {
        if index >= renderLimit - 25 && renderLimit < displayedSongs.count {
            renderLimit = min(renderLimit + 120, displayedSongs.count)
        }
    }
    /// 各文件夹内容概要（含歌/子文件夹 + 封面预览歌），用于隐藏无音乐文件夹与取封面。
    @State private var folderOverviews: [String: SynologyFolderOverview] = [:]
    @State private var isSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var showBatchEditor = false
    @State private var showBatchAddToPlaylist = false
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var overviewTask: Task<Void, Never>? = nil

    private var selectedSongs: [Song] {
        displayedSongs.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private var songs: [Song] {
        displayedSongs
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let songList = displayedSongs
        guard startIndex >= 0, startIndex < songList.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedSongKeys
            let willSelect = !selectedSongKeys.contains(songList[startIndex].identityKey)
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedKeysOnDrag else { return }
        let current = min(max(0, start + deltaRows), songList.count - 1)
        guard current != lastDragIndex else { return }
        lastDragIndex = current
        ATMusicHaptics.select()

        let low = min(start, current)
        let high = max(start, current)
        var updated = initial
        for idx in low...high {
            let key = songList[idx].identityKey
            if dragTargetSelected {
                updated.insert(key)
            } else {
                updated.remove(key)
            }
        }
        selectedSongKeys = updated
    }

    private func handleDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
    }

    init(folderID: String?, title: String, breadcrumbs: [String] = ["NAS"]) {
        self.folderID = folderID
        self.title = title
        self.breadcrumbs = breadcrumbs
    }
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var query = ""

    /// 高性能增量过滤排序：绝不每次求值重复遍历与多次本地化比较，彻底杜绝滑动掉帧卡顿
    private func updateDisplayedContent() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = keyword.isEmpty ? items : items.filter { item in
            if item.name.lowercased().contains(keyword) { return true }
            if let song = item.song {
                return song.name.lowercased().contains(keyword)
                    || song.artists.lowercased().contains(keyword)
                    || song.album.lowercased().contains(keyword)
            }
            return false
        }
        // 隐藏十级子文件夹内无支持音频文件的文件夹：概要未回先显示，确认无音乐后再收起。
        let musicOnly = filtered.filter { item in
            if item.kind == .song { return true }
            guard let ov = folderOverviews[item.id] else { return true }
            return ov.hasSupportedAudio
        }

        var folders: [SynologyFolderItem] = []
        var songList: [Song] = []
        folders.reserveCapacity(musicOnly.count)
        songList.reserveCapacity(musicOnly.count)

        for item in musicOnly {
            if item.kind == .folder {
                folders.append(item)
            } else if let song = item.song {
                songList.append(song)
            }
        }

        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.displayedFolders = folders
        self.displayedSongs = songList
        self.renderLimit = min(100, max(songList.count, 0))
    }

    private var breadcrumbsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                    HStack(spacing: 6) {
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.atmusicComment.opacity(0.5))
                        }
                        Text(crumb)
                            .font(ATMusicFont.appFont(12, idx == breadcrumbs.count - 1 ? .semibold : .medium))
                            .foregroundStyle(idx == breadcrumbs.count - 1 ? Color.atmusicAmber : Color.atmusicComment)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(idx == breadcrumbs.count - 1 ? Color.atmusicAmber.opacity(0.12) : Color.primary.opacity(0.04))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func folderRow(_ item: SynologyFolderItem) -> some View {
        NavigationLink {
            SynologyFolderView(
                folderID: item.id,
                title: item.name,
                breadcrumbs: breadcrumbs + [item.name]
            )
            .environmentObject(theme)
            .environmentObject(player)
        } label: {
            SynologyLibraryRow(
                coverURL: folderOverviews[item.id]?.previewSong?.coverURL,
                title: item.name,
                subtitle: "文件夹",
                systemImage: "folder.fill"
            )
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func batchDownloadAllFolderSongs() {
        guard !displayedSongs.isEmpty else { return }
        ATMusicHaptics.medium()
        let quality: DownloadQuality
        let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        DownloadManager.shared.startBatchDownload(songs: displayedSongs, quality: quality)
        ToastCenter.shared.show("已将 \(displayedSongs.count) 首曲目加入离线下载")
    }

    var body: some View {
        ZStack {
            GlassBackdrop()
            if !synology.isLoggedIn {
                EmptyStateView(icon: "externaldrive.badge.xmark", text: "请先在“我的”中连接群晖 NAS")
            } else if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                List {
                    Section {
                        breadcrumbsView
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if !displayedSongs.isEmpty {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    player.play(songs: displayedSongs, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    player.play(songs: displayedSongs.shuffled(), startAt: 0)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    if !displayedFolders.isEmpty {
                        Section {
                            ForEach(displayedFolders) { item in
                                folderRow(item)
                            }
                        } header: {
                            Text("文件夹 (\(displayedFolders.count))")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicComment)
                                .padding(.horizontal, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    if !displayedSongs.isEmpty {
                        Section {
                            ForEach(Array(visibleSongs.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(
                                    song: song,
                                    glassRow: false,
                                    playbackContext: displayedSongs,
                                    playbackIndex: index,
                                    onTap: {
                                        player.play(songs: displayedSongs, startAt: index)
                                    },
                                    isMultiSelecting: isSelecting,
                                    isSelected: selectedSongKeys.contains(song.identityKey),
                                    onToggleSelection: {
                                        toggleSelection(song)
                                    },
                                    onDragSelectionChange: { startIdx, deltaRows in
                                        handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
                                    },
                                    onDragSelectionEnd: {
                                        handleDragEnd()
                                    },
                                    selectionIndex: index
                                )
                                .onAppear {
                                    loadMoreSongsIfNeeded(at: index)
                                }
                            }
                        } header: {
                            if !displayedFolders.isEmpty {
                                Text("曲目 (\(displayedSongs.count))")
                                    .font(ATMusicFont.appFont(13, .semibold))
                                    .foregroundStyle(Color.atmusicComment)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .atmusicScrollContentBackgroundHidden()
                .listStyle(.plain)
            }
        }
        .navigationTitle(isSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索当前文件夹")
        .onChange(of: query) { _ in
            updateDisplayedContent()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !displayedSongs.isEmpty {
                    if isSelecting {
                        HStack(spacing: 12) {
                            Button(selectedSongKeys.count == displayedSongs.count ? "取消全选" : "全选") {
                                ATMusicHaptics.tap()
                                if selectedSongKeys.count == displayedSongs.count {
                                    selectedSongKeys.removeAll()
                                } else {
                                    selectedSongKeys = Set(displayedSongs.map(\.identityKey))
                                }
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)

                            Button("完成") {
                                ATMusicHaptics.tap()
                                isSelecting = false
                                selectedSongKeys.removeAll()
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                        }
                    } else {
                        Menu {
                            Button {
                                ATMusicHaptics.select()
                                isSelecting = true
                            } label: {
                                Label("多选歌曲", systemImage: "checklist")
                            }

                            Button {
                                batchDownloadAllFolderSongs()
                            } label: {
                                Label("下载全部曲目", systemImage: "arrow.down.circle")
                            }

                            Button {
                                player.appendToQueue(songs: displayedSongs)
                                ToastCenter.shared.show("已将全部 \(displayedSongs.count) 首加入队列")
                            } label: {
                                Label("全部加至播放队列", systemImage: "text.badge.plus")
                            }

                            Button {
                                showBatchEditor = true
                            } label: {
                                Label("批量编辑 NAS 标签", systemImage: "square.and.pencil")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("更多操作")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selectedSongKeys.isEmpty {
                UniversalBatchActionBar(
                    selectedCount: selectedSongKeys.count,
                    totalCount: displayedSongs.count,
                    actions: [
                        BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                            let selected = selectedSongs
                            player.play(songs: selected, startAt: 0)
                            isSelecting = false
                            selectedSongKeys.removeAll()
                        },
                        BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            let selected = selectedSongs
                            player.playNext(songs: selected)
                            isSelecting = false
                            selectedSongKeys.removeAll()
                        },
                        BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                            let selected = selectedSongs
                            player.appendToQueue(songs: selected)
                            isSelecting = false
                            selectedSongKeys.removeAll()
                        },
                        BatchActionItem(id: "playlist", title: "加歌单", systemImage: "folder.badge.plus") {
                            showBatchAddToPlaylist = true
                        },
                        BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                            let selected = selectedSongs
                            let quality: DownloadQuality
                            let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
                            if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
                                quality = ThirdPartyAudioQuality.current
                            } else {
                                quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
                            }
                            DownloadManager.shared.startBatchDownload(songs: selected, quality: quality)
                            isSelecting = false
                            selectedSongKeys.removeAll()
                        },
                        BatchActionItem(id: "edit", title: "批量编辑", systemImage: "square.and.pencil", tint: Color.atmusicAmber) {
                            showBatchEditor = true
                        }
                    ]
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showBatchEditor) {
            let selected = selectedSongs
            SynologyBatchMetadataEditorSheet(songs: selected, keyword: selected.first?.name ?? "")
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showBatchAddToPlaylist) {
            AddToPlaylistSheet(songs: selectedSongs)
                .environmentObject(theme)
        }
        .task { if synology.isLoggedIn { await load(force: false) } }
        .refreshable {
            await load(force: true)
        }
        .onDisappear {
            overviewTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSynologyMetadataDidUpdate)) { note in
            if let updated = note.object as? Song {
                for i in items.indices {
                    if let s = items[i].song,
                       (s.identityKey == updated.identityKey || LocalLibraryStore.isMatchingSong(s, updated) || (s.source == updated.source && s.id == updated.id && s.id != 0)) {
                        items[i] = SynologyFolderItem(id: items[i].id, name: items[i].kind == .song ? updated.name : items[i].name, kind: items[i].kind, song: updated, path: items[i].path)
                    }
                }
                updateDisplayedContent()
            }
        }
    }

    private func load(force: Bool = false) async {
        guard synology.isLoggedIn else {
            isLoading = false
            return
        }

        errorMessage = nil

        if force {
            synology.invalidateFolderCache(folderID: folderID)
        } else if let fresh = synology.cachedFolderItems(folderID: folderID, allowStale: false) {
            items = fresh
            updateDisplayedContent()
            isLoading = false
            refreshFolderOverviews()
            return
        } else if let stale = synology.cachedFolderItems(folderID: folderID, allowStale: true) {
            // 旧缓存先展示，网络刷新在后面静默进行。
            items = stale
            updateDisplayedContent()
            isLoading = false
            refreshFolderOverviews()
        }

        isLoading = items.isEmpty
        let pageSize = 120
        var loaded: [SynologyFolderItem] = []
        var offset = 0

        do {
            while !Task.isCancelled, offset < 10_000 {
                let page = try await synology.folderItems(
                    folderID: folderID,
                    offset: offset,
                    limit: pageSize
                )
                guard !Task.isCancelled else { return }
                if page.isEmpty { break }

                loaded.append(contentsOf: page)
                offset += page.count
                if page.count < pageSize { break }
            }

            guard !Task.isCancelled else { return }

            var seen = Set<String>()
            let deduplicated = loaded.filter { seen.insert("\($0.kind.rawValue)|\($0.id)").inserted }

            if !deduplicated.isEmpty {
                synology.cacheFolderItems(deduplicated, folderID: folderID)
            } else if items.isEmpty {
                synology.cacheFolderItems([], folderID: folderID)
            }

            if items != deduplicated {
                items = deduplicated
                updateDisplayedContent()
            }
            refreshFolderOverviews()
            isLoading = false
        } catch {
            isLoading = false
            // 有旧缓存时保持可浏览，不用错误页覆盖已有内容。
            if items.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log("NAS 文件夹后台刷新失败：\(error.localizedDescription)", level: .debug)
            }
        }
    }

    /// 渐进式轻量刷新文件夹概要：优先命中内存与磁盘缓存，未命中走限流并发（最大 3 并发），绝不堵塞主线程
    private func refreshFolderOverviews() {
        overviewTask?.cancel()
        let folderList = items.filter { $0.kind == .folder }
        guard !folderList.isEmpty else {
            folderOverviews = [:]
            updateDisplayedContent()
            return
        }

        var currentOverviews = folderOverviews
        var uncachedFolders: [SynologyFolderItem] = []

        for f in folderList {
            if let existing = synology.cachedFolderOverview(folderID: f.id, folderPath: f.path) {
                currentOverviews[f.id] = existing
            } else {
                uncachedFolders.append(f)
            }
        }

        if currentOverviews != folderOverviews {
            folderOverviews = currentOverviews
            updateDisplayedContent()
        }

        guard !uncachedFolders.isEmpty else { return }

        overviewTask = Task {
            let concurrency = 3
            var cursor = 0
            await withTaskGroup(of: (String, SynologyFolderOverview).self) { group in
                while cursor < min(concurrency, uncachedFolders.count) {
                    let folder = uncachedFolders[cursor]
                    cursor += 1
                    group.addTask {
                        (folder.id, await synology.folderOverview(folderID: folder.id, folderPath: folder.path))
                    }
                }

                for await (id, ov) in group {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        folderOverviews[id] = ov
                        updateDisplayedContent()
                    }
                    if cursor < uncachedFolders.count {
                        let nextFolder = uncachedFolders[cursor]
                        cursor += 1
                        group.addTask {
                            (nextFolder.id, await synology.folderOverview(folderID: nextFolder.id, folderPath: nextFolder.path))
                        }
                    }
                }
            }
        }
    }
}

/// 批量编辑 NAS 歌曲信息：统一修改演出者、专辑名称、专辑演出者、流派、年份、备注与封面，逐首写入 NAS 标签。
struct SynologyBatchMetadataEditorSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    let songs: [Song]
    let keyword: String

    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var genre = ""
    @State private var year = ""
    @State private var comment = ""
    @State private var trackStart = "1"
    @State private var discOverride = ""
    @State private var sequentialEnabled = false
    @State private var numberingOverrides: [String: TrackNumberingOverride] = [:]
    @State private var numberingOrder: [String] = []
    @State private var selectedCoverURL: URL?
    @State private var selectedCoverData: Data?
    @State private var selectedCoverThumbnail: UIImage?
    @State private var isSaving = false
    @State private var message = ""
    @State private var showCoverPicker = false
    @State private var savedCount: Int?

    private var discOverrideNumber: Int? {
        TrackSequencing.parseNumber(discOverride, range: 1...999)
    }

    private var numberingPlan: TrackSequencing.Plan {
        TrackSequencing.plan(
            songs: songs,
            order: numberingOrder,
            discOverride: discOverrideNumber,
            startTrack: TrackSequencing.parseNumber(trackStart, range: 1...999) ?? 1
        )
    }

    var body: some View {
        NavigationView {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 1. 顶部选中歌曲概览
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("批量设置 \(songs.count) 首群晖 NAS 歌曲")
                                    .font(ATMusicFont.appFont(15, .semibold))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                if let savedCount {
                                    Text("已写入 \(savedCount)/\(songs.count) 首")
                                        .font(ATMusicFont.appFont(13, .semibold))
                                        .foregroundStyle(theme.accent.highlight)
                                }
                            }
                            // 歌曲横向预览
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(songs.prefix(15)), id: \.identityKey) { s in
                                        HStack(spacing: 6) {
                                            CoverImage(url: s.coverURL, size: 28, cornerRadius: 6)
                                            Text(s.name)
                                                .font(ATMusicFont.appFont(12))
                                                .foregroundStyle(Color.atmusicLabel)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                    }
                                    if songs.count > 15 {
                                        Text("等共 \(songs.count) 首")
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // 2. 统一专辑封面设置
                        VStack(alignment: .leading, spacing: 10) {
                            Text("专辑封面（可选）")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicComment)
                            Button {
                                showCoverPicker = true
                            } label: {
                                HStack(spacing: 12) {
                                    if let selectedCoverThumbnail {
                                        Image(uiImage: selectedCoverThumbnail)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    } else if let selectedCoverData, let img = UIImage(data: selectedCoverData) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    } else if let selectedCoverURL {
                                        CoverImage(url: selectedCoverURL, size: 48, cornerRadius: 10)
                                    } else {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(width: 48, height: 48)
                                            .overlay {
                                                Image(systemName: "photo.badge.plus")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(Color.atmusicAmber)
                                            }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selectedCoverData != nil || selectedCoverURL != nil ? "已选择新封面" : "点击选择统一专辑封面")
                                            .font(ATMusicFont.appFont(14, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                        Text(selectedCoverData != nil || selectedCoverURL != nil ? "所有选中的 NAS 歌曲将统一绑定该封面" : "支持在线搜索或从相册选择")
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                    Spacer()
                                    if selectedCoverData != nil || selectedCoverURL != nil || selectedCoverThumbnail != nil {
                                        Button {
                                            selectedCoverData = nil
                                            selectedCoverURL = nil
                                            selectedCoverThumbnail = nil
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundStyle(Color.atmusicComment)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.atmusicComment.opacity(0.5))
                                    }
                                }
                                .padding(12)
                                .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        // 3. 元数据输入字段
                        VStack(alignment: .leading, spacing: 10) {
                            Text("标签字段（留空项保持原样不变）")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicComment)

                            VStack(spacing: 8) {
                                nasBatchInputField(title: "演出者", placeholder: "留空保持原样", text: $artist)
                                nasBatchInputField(title: "专辑名称", placeholder: "留空保持原样", text: $album)
                                nasBatchInputField(title: "专辑演出者", placeholder: "留空保持原样", text: $albumArtist)
                                nasBatchInputField(title: "流派", placeholder: "留空保持原样", text: $genre)
                                nasBatchInputField(title: "专辑年份", placeholder: "留空保持原样", text: $year, keyboard: .numberPad)
                                nasBatchInputField(title: "备注", placeholder: "留空保持原样", text: $comment)
                            }
                            .padding(12)
                            .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        // 3.5 曲目编号（盘号 / 音轨号）
                        TrackNumberingCard(
                            songs: songs,
                            order: $numberingOrder,
                            startTrack: $trackStart,
                            discOverride: $discOverride,
                            sequentialEnabled: $sequentialEnabled,
                            overrides: $numberingOverrides
                        )

                        if !message.isEmpty {
                            Text(message)
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(theme.accent.highlight)
                        }

                        if isSaving {
                            ProgressView(value: Double(savedCount ?? 0), total: Double(songs.count))
                                .tint(Color.atmusicAmber)
                                .padding(.vertical, 4)
                        }

                        GlassButton(
                            title: isSaving ? "正在逐首写入 NAS…" : "保存并写入 \(songs.count) 首 NAS 歌曲",
                            systemName: "square.and.arrow.down",
                            prominent: true
                        ) {
                            Task { await save() }
                        }
                        .disabled(isSaving)
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("批量编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            if let first = songs.first {
                SongCoverSearchGridSheet(song: first) { candidate in
                    selectedCoverURL = candidate.song.coverURL
                    selectedCoverData = nil
                    selectedCoverThumbnail = nil
                    showCoverPicker = false
                } onPickData: { data in
                    let optimized = SynologyAPI.shared.optimizedCoverData(data)
                    selectedCoverData = optimized
                    selectedCoverThumbnail = UIImage(data: optimized)
                    selectedCoverURL = nil
                    showCoverPicker = false
                }
            }
        }
    }

    @ViewBuilder
    private func nasBatchInputField(title: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(ATMusicFont.appFont(14))
                .foregroundStyle(Color.atmusicLabel)
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: text)
                .font(ATMusicFont.appFont(14))
                .keyboardType(keyboard)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private func save() async {
        guard !isSaving else { return }
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbumArtist = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedYear = year.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        let basePatch = SynologyTagPatch(
            title: nil,
            artist: trimmedArtist.isEmpty ? nil : trimmedArtist,
            album: trimmedAlbum.isEmpty ? nil : trimmedAlbum,
            albumArtist: trimmedAlbumArtist.isEmpty ? nil : trimmedAlbumArtist,
            genre: trimmedGenre.isEmpty ? nil : trimmedGenre,
            year: trimmedYear.isEmpty ? nil : trimmedYear,
            comment: trimmedComment.isEmpty ? nil : trimmedComment
        )
        let numberingActive = sequentialEnabled || discOverrideNumber != nil || !numberingOverrides.isEmpty
        if basePatch.isEmpty && !numberingActive && selectedCoverURL == nil && selectedCoverData == nil {
            await MainActor.run { message = "没有可写入的内容（字段均留空且未选择封面）" }
            return
        }
        let plan = sequentialEnabled ? numberingPlan : nil
        await MainActor.run { isSaving = true; message = "正在准备封面与元数据…" }

        var preparedCoverData = selectedCoverData
        var preparedCoverImage: UIImage? = selectedCoverData.flatMap { UIImage(data: $0) }
        if preparedCoverData == nil, let coverURL = selectedCoverURL {
            if coverURL.isFileURL {
                if let data = try? Data(contentsOf: coverURL), let img = UIImage(data: data) {
                    preparedCoverData = data
                    preparedCoverImage = img
                }
            } else {
                var req = URLRequest(url: coverURL)
                req.timeoutInterval = 20
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   !data.isEmpty, let img = UIImage(data: data) {
                    preparedCoverData = data
                    preparedCoverImage = img
                }
            }
        }

        // 预先优化并压缩待写入封面，防止循环中频繁重复进行耗内存的大图解码
        if let raw = preparedCoverData {
            let optimized = SynologyAPI.shared.optimizedCoverData(raw)
            preparedCoverData = optimized
            preparedCoverImage = UIImage(data: optimized)
        } else if selectedCoverURL != nil {
            await MainActor.run {
                isSaving = false
                message = "封面下载失败，请检查网络或重新选择图片"
            }
            return
        }

        await MainActor.run { message = "正在批量写入 NAS…" }
        var saved = 0
        var allUpdatedSongs: [Song] = []
        for song in songs {
            // 曲目编号逐首不同：按预排的结果生成本首专属 patch，其余字段沿用统一输入。
            let numbers = plan?.assignment(for: song.identityKey)
            let manual = numberingOverrides[song.identityKey]
            let discForSong = manual.flatMap { TrackSequencing.parseNumber($0.disc, range: 1...999) }
                ?? numbers?.disc
                ?? discOverrideNumber
            // 手改优先：清空格子即「该曲不写曲目号」，不再回落到自动编号
            let trackForSong: Int? = manual.map { TrackSequencing.parseNumber($0.track, range: 0...999) ?? 0 } ?? numbers?.track
            let patch = SynologyTagPatch(
                title: basePatch.title,
                artist: basePatch.artist,
                album: basePatch.album,
                albumArtist: basePatch.albumArtist,
                genre: basePatch.genre,
                year: basePatch.year,
                comment: basePatch.comment,
                track: trackForSong.flatMap { $0 > 0 ? String($0) : nil },
                disc: discForSong.map { String($0) }
            )
            if patch.isEmpty && preparedCoverData == nil {
                saved += 1
                continue
            }
            do {
                try await SynologyAPI.shared.applyMetadata(
                    song: song,
                    patch: patch,
                    coverURL: nil,
                    coverData: preparedCoverData,
                    skipCacheInvalidation: true,
                    skipVerification: true
                )
                let refreshedCover = SynologyAPI.shared.coverURL(
                    songId: song.synologyId ?? "\(song.id)",
                    cacheBust: UUID().uuidString
                )
                let updated = Song(
                    id: song.id,
                    name: song.name,
                    artists: trimmedArtist.isEmpty ? song.artists : trimmedArtist,
                    album: trimmedAlbum.isEmpty ? song.album : trimmedAlbum,
                    coverURL: refreshedCover ?? song.coverURL,
                    duration: song.duration,
                    source: song.source,
                    synologyId: song.synologyId,
                    synologyServerScope: song.synologyServerScope,
                    synologyPath: song.synologyPath,
                    albumArtist: trimmedAlbumArtist.isEmpty ? song.albumArtist : trimmedAlbumArtist,
                    genre: trimmedGenre.isEmpty ? song.genre : trimmedGenre,
                    year: trimmedYear.isEmpty ? song.year : trimmedYear,
                    comment: trimmedComment.isEmpty ? song.comment : trimmedComment,
                    discNumber: discForSong ?? song.discNumber,
                    trackNumber: trackForSong ?? song.trackNumber,
                    fee: song.fee
                )
                allUpdatedSongs.append(updated)

                if let preparedCoverImage {
                    if let refreshedCover {
                        ATMusicRemoteCoverCache.store(preparedCoverImage, for: refreshedCover)
                    }
                    if let oldCover = song.coverURL {
                        ATMusicRemoteCoverCache.store(preparedCoverImage, for: oldCover)
                    }
                }
                saved += 1
                await MainActor.run {
                    savedCount = saved
                    message = "正在批量写入 NAS…（\(saved)/\(songs.count)）"
                }
            } catch {
                await MainActor.run { message = "第 \(saved + 1) 首写入失败：\(error.localizedDescription)" }
            }
        }

        // 批量落盘与索引更新，单次完成以消除巨额 I/O 与并发视图刷新假死
        if !allUpdatedSongs.isEmpty {
            DetailSongsCache.shared.updateSongs(allUpdatedSongs)
            SynologyAPI.shared.updateCachedLibrarySongs(allUpdatedSongs)
            await MainActor.run {
                for updated in allUpdatedSongs {
                    if player.currentSong?.identityKey == updated.identityKey {
                        player.replaceSong(updated)
                    }
                }
                NotificationCenter.default.post(name: .atmusicSynologyMetadataDidUpdate, object: nil)
                NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: nil)
            }
        }

        await MainActor.run {
            isSaving = false
            if saved > 0 {
                SynologyAPI.shared.invalidateAllFolderCaches()
            }
            if saved == songs.count {
                ATMusicHaptics.success()
                ToastCenter.shared.show("批量写入完成（\(saved) 首已更新）")
                dismiss()
            } else {
                savedCount = saved
                message = "写入结束：成功 \(saved) 首，失败 \(songs.count - saved) 首"
            }
        }
    }
}

/// NAS 歌手详情：使用歌手歌曲中的第一张封面作为头像，并把该歌手的专辑与歌曲分区展示。
struct SynologyArtistView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let artistName: String
    let coverURL: URL?
    let initialSongs: [Song]
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedSection: ArtistDetailSection = .songs
    @State private var selectedAlbum: Song?

    private enum ArtistDetailSection: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case albums = "专辑"

        var id: String { rawValue }
    }

    init(artistName: String, coverURL: URL?, initialSongs: [Song] = []) {
        self.artistName = artistName
        self.coverURL = coverURL
        self.initialSongs = initialSongs
    }

    private var albums: [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.album).inserted }
    }

    var body: some View {
        ZStack {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage, songs.isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        artistHeader
                        Picker("歌手内容", selection: $selectedSection) {
                            ForEach(ArtistDetailSection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 2)

                        if selectedSection == .songs {
                            songsSection
                        } else if !albums.isEmpty {
                            albumSection
                        } else {
                            Text("该歌手暂无专辑")
                                .font(ATMusicFont.appFont(13))
                                .foregroundStyle(Color.atmusicComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .atmusicScrollIndicatorsHidden()
            }
        }
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSynologyMetadataDidUpdate)) { note in
            if let updated = note.object as? Song {
                for i in songs.indices {
                    let s = songs[i]
                    if s.identityKey == updated.identityKey || LocalLibraryStore.isMatchingSong(s, updated) || (s.source == updated.source && s.id == updated.id && s.id != 0) {
                        songs[i] = updated
                    }
                }
            }
        }
        .sheet(item: $selectedAlbum) { item in
            ATMusicNavigationStack {
                SynologyAlbumView(
                    albumName: item.album,
                    artistName: artistName,
                    coverURL: item.coverURL,
                    initialSongs: songs.filter { $0.album == item.album }
                )
            }
            .environmentObject(player)
        }
    }

    private var artistHeader: some View {
        HStack(spacing: 14) {
            CoverImage(url: songs.first?.coverURL ?? coverURL, size: 84, cornerRadius: 42)
            VStack(alignment: .leading, spacing: 6) {
                Text(artistName)
                    .font(ATMusicFont.appFont(22, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                Text("\(albums.count) 张专辑 · \(songs.count) 首歌曲")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer(minLength: 0)
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "专辑")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 16) {
                ForEach(albums) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        MediaSquareCard(title: album.album, subtitle: "\(songsForAlbum(album).count) 首", coverURL: album.coverURL, showSourceBadge: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "歌曲")
                Spacer()
            if !songs.isEmpty {
                    Button {
                        ATMusicHaptics.tap()
                        player.play(songs: songs, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                }
            }
            if songs.isEmpty {
                Text("该歌手暂无歌曲")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index, onTap: {
                        player.play(songs: songs, startAt: index)
                    })
                    }
                }
            }
        }
    }

    private func songsForAlbum(_ album: Song) -> [Song] {
        songs.filter { $0.album == album.album }
    }

    private func load() async {
        guard synology.isLoggedIn else {
            isLoading = false
            errorMessage = "请先连接群晖 NAS"
            return
        }
        let names = [artistName, simplifiedArtistName(artistName)]
        let matches: ([Song]) -> [Song] = { source in
            source.filter { song in
                let songArtists = song.artists.components(separatedBy: " / ")
                return songArtists.contains { name in
                    names.contains { normalizedArtistName($0) == normalizedArtistName(name) }
                }
            }
        }

        // 从搜索结果、音乐库列表或首页传入的歌曲先展示，避免歌手页首屏等待完整 NAS 目录。
        let preview = matches(initialSongs)
        if !preview.isEmpty {
            songs = preview
            isLoading = false
        }

        do {
            let allSongs = try await synology.librarySongs()
            let loadedSongs = matches(allSongs)
            if !loadedSongs.isEmpty || preview.isEmpty {
                songs = loadedSongs
            }
            isLoading = false
        } catch {
            if preview.isEmpty {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func normalizedArtistName(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let simplified = String(folded.map { character in
            switch character {
            case "倫": return "伦"; case "傑": return "杰"; case "華": return "华"; case "樂": return "乐"
            case "臺": return "台"; case "灣": return "湾"; case "國": return "国"; case "龍": return "龙"
            default: return character
            }
        })
        let compact = simplified.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        if compact == "jaychou" { return "周杰伦" }
        return compact
    }

    private func simplifiedArtistName(_ value: String) -> String {
        String(value.map { character in
            switch character {
            case "倫": return "伦"; case "傑": return "杰"; case "華": return "华"; case "樂": return "乐"
            case "臺": return "台"; case "灣": return "湾"; case "國": return "国"; case "龍": return "龙"
            default: return character
            }
        })
    }
}

/// NAS 专辑详情，结构与 Apple Music 的专辑页一致：头部封面、播放操作、歌曲列表。
struct SynologyAlbumView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var synology = SynologyAPI.shared

    let albumName: String
    let artistName: String
    let coverURL: URL?
    /// 搜索页打开专辑时传入的首批歌曲，用于先渲染详情页，避免等待完整 NAS 索引。
    var initialSongs: [Song] = []
    var isModal: Bool = true
    @State private var tracks: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isBatchDownloading = false
    @State private var showBatchEditor = false
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false

    private var selectedSongs: [Song] {
        sortedTracks.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = sortedTracks.map(\.identityKey)
        guard startIndex >= 0, startIndex < keys.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedSongKeys
            let willSelect = !selectedSongKeys.contains(keys[startIndex])
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedKeysOnDrag else { return }
        let current = min(max(0, start + deltaRows), keys.count - 1)
        guard current != lastDragIndex else { return }
        lastDragIndex = current
        ATMusicHaptics.select()

        let low = min(start, current)
        let high = max(start, current)
        var updated = initial
        for idx in low...high {
            let k = keys[idx]
            if dragTargetSelected {
                updated.insert(k)
            } else {
                updated.remove(k)
            }
        }
        selectedSongKeys = updated
    }

    private func handleDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
    }

    @ViewBuilder
    private func albumSongRow(song: Song, index: Int, playbackIndex: Int, trackNumber: Int) -> some View {
        SongCell(
            song: song,
            glassRow: true,
            playbackContext: sortedTracks,
            playbackIndex: playbackIndex,
            trackNumber: trackNumber,
            onTap: {
                player.play(songs: sortedTracks, startAt: playbackIndex)
            },
            isMultiSelecting: isMultiSelecting,
            isSelected: selectedSongKeys.contains(song.identityKey),
            onToggleSelection: {
                toggleSelection(song)
            },
            onDragSelectionChange: { startIdx, deltaRows in
                handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
            },
            onDragSelectionEnd: {
                handleDragEnd()
            },
            selectionIndex: index
        )
    }

    @MainActor
    private func batchDownloadAlbum() {
        guard !sortedTracks.isEmpty else { return }
        isBatchDownloading = true
        ATMusicHaptics.medium()
        ATMusicHaptics.medium()
        let quality: DownloadQuality
        let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        DownloadManager.shared.startBatchDownload(songs: sortedTracks, quality: quality)
    }

    /// 严格双键保序排列：优先盘号 discNumber，再按音轨号 trackNumber，最后按全局 ID 保序
    private var sortedTracks: [Song] {
        tracks.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
            return $0.id < $1.id
        }
    }

    /// 多 CD 分组模型（Apple Music 规范，支持显式 discNumber 与隐式音轨重置识别）
    private var discGroups: [(disc: Int, songs: [Song])] {
        let explicit = Dictionary(grouping: sortedTracks, by: { $0.discNumber })
        if explicit.keys.count > 1 {
            return explicit.keys.sorted().map { ($0, explicit[$0]!) }
        }
        // 隐式检测：若 discNumber 全为 1，但曲目号重置为 1（典型多 CD 唱片未打盘号标签）
        var groups: [(disc: Int, songs: [Song])] = []
        var currentDisc = 1
        var currentSongs: [Song] = []
        var prevTrack = 0
        for song in sortedTracks {
            let trk = song.trackNumber
            if trk == 1 && prevTrack >= 1 && !currentSongs.isEmpty {
                groups.append((disc: currentDisc, songs: currentSongs))
                currentDisc += 1
                currentSongs = [song]
                prevTrack = 1
            } else {
                currentSongs.append(song)
                if trk > 0 { prevTrack = trk }
            }
        }
        if !currentSongs.isEmpty {
            groups.append((disc: currentDisc, songs: currentSongs))
        }
        if groups.count > 1 {
            return groups
        }
        return explicit.keys.sorted().map { ($0, explicit[$0]!) }
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            if isLoading {
                LoadingStateView()
            } else if let errorMessage, tracks.isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                iPadAlbumLayout
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        albumHeader
                        if !sortedTracks.isEmpty {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    player.play(songs: sortedTracks, startAt: 0)
                                }
                                .frame(maxWidth: .infinity)

                                GlassButton(title: "随机播放", systemName: "shuffle", prominent: false) {
                                    guard !sortedTracks.isEmpty else { return }
                                    player.play(songs: sortedTracks.shuffled(), startAt: 0)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 16)
                        }

                        // 多 CD 分栏或普通歌曲列表
                        if discGroups.count > 1 {
                            ForEach(discGroups, id: \.disc) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    discSectionHeader(discNumber: group.disc, songs: group.songs)
                                    ForEach(Array(group.songs.enumerated()), id: \.element.identityKey) { index, song in
                                        let displayNo = (song.trackNumber >= 1 && song.trackNumber <= group.songs.count) ? song.trackNumber : (index + 1)
                                        let globalIndex = sortedTracks.firstIndex(of: song) ?? 0
                                        albumSongRow(song: song, index: globalIndex, playbackIndex: globalIndex, trackNumber: displayNo)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(title: "歌曲")
                                ForEach(Array(sortedTracks.enumerated()), id: \.element.identityKey) { index, song in
                                    let displayNo = (song.trackNumber >= 1 && song.trackNumber <= sortedTracks.count) ? song.trackNumber : (index + 1)
                                    albumSongRow(song: song, index: index, playbackIndex: index, trackNumber: displayNo)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
                .atmusicScrollIndicatorsHidden()
            }

            if isMultiSelecting && !selectedSongKeys.isEmpty {
                VStack {
                    Spacer()
                    UniversalBatchActionBar(
                        selectedCount: selectedSongKeys.count,
                        totalCount: sortedTracks.count,
                        actions: [
                            BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                                let songs = selectedSongs
                                player.play(songs: songs, startAt: 0)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                let songs = selectedSongs
                                player.playNext(songs: songs)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                                let songs = selectedSongs
                                player.appendToQueue(songs: songs)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "playlist", title: "加歌单", systemImage: "folder.badge.plus") {
                                showBatchAddToPlaylist = true
                            },
                            BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                                let songs = selectedSongs
                                let quality: DownloadQuality
                                let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
                                if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
                                    quality = ThirdPartyAudioQuality.current
                                } else {
                                    quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
                                }
                                DownloadManager.shared.startBatchDownload(songs: songs, quality: quality)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "edit", title: "批量编辑", systemImage: "square.and.pencil", tint: Color.atmusicAmber) {
                                showBatchEditor = true
                            }
                        ]
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : albumName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isMultiSelecting {
                    Button(selectedSongKeys.count == sortedTracks.count && !sortedTracks.isEmpty ? "取消全选" : "全选") {
                        ATMusicHaptics.tap()
                        if selectedSongKeys.count == sortedTracks.count {
                            selectedSongKeys.removeAll()
                        } else {
                            selectedSongKeys = Set(sortedTracks.map(\.identityKey))
                        }
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicAmber)

                    Button("完成") {
                        ATMusicHaptics.tap()
                        isMultiSelecting = false
                        selectedSongKeys.removeAll()
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                } else {
                    Menu {
                        Button {
                            ATMusicHaptics.select()
                            isMultiSelecting = true
                        } label: {
                            Label("多选歌曲", systemImage: "checklist")
                        }
                        .disabled(sortedTracks.isEmpty)

                        Button {
                            batchDownloadAlbum()
                        } label: {
                            Label(isBatchDownloading ? "正在加入下载..." : "下载全专歌曲", systemImage: "arrow.down.circle")
                        }
                        .disabled(sortedTracks.isEmpty || isBatchDownloading)

                        Button {
                            showBatchEditor = true
                        } label: {
                            Label("批量编辑全专信息", systemImage: "square.and.pencil")
                        }
                        .disabled(sortedTracks.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多操作")

                    if isModal {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.atmusicComment.opacity(0.8))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showBatchAddToPlaylist) {
            AddToPlaylistSheet(songs: selectedSongs)
                .environmentObject(theme)
        }
                .task { await load() }
        .sheet(isPresented: $showBatchEditor) {
            SynologyBatchMetadataEditorSheet(songs: sortedTracks, keyword: albumName)
                .environmentObject(player)
                .environmentObject(theme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSynologyMetadataDidUpdate)) { note in
            if let updated = note.object as? Song {
                for i in tracks.indices {
                    let s = tracks[i]
                    if s.identityKey == updated.identityKey || LocalLibraryStore.isMatchingSong(s, updated) || (s.source == updated.source && s.id == updated.id && s.id != 0) {
                        tracks[i] = updated
                    }
                }
            } else {
                Task { await load() }
            }
        }
    }

    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 16) {
                CoverImage(url: sortedTracks.first?.coverURL ?? coverURL, size: 160, cornerRadius: 18)
                VStack(alignment: .leading, spacing: 7) {
                    // 群晖 NAS 专属琥珀流光徽标
                    HStack(spacing: 4) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("群晖 NAS · 私有无损库")
                            .font(ATMusicFont.appFont(11, .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.atmusicAmber.opacity(0.18))
                    .foregroundStyle(Color.atmusicAmber)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.atmusicAmber.opacity(0.35), lineWidth: 0.8)
                    )

                    Text(albumName)
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(3)
                    Text(artistName.isEmpty ? "未知歌手" : artistName)
                        .font(ATMusicFont.appFont(14, .medium))
                        .foregroundStyle(artistName.isEmpty ? Color.atmusicComment : Color.atmusicAmber)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(atmusicSongCountText(sortedTracks.count))
                        if discGroups.count > 1 {
                            Text("· \(discGroups.count) CD 大碟")
                                .font(ATMusicFont.appFont(12, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                    }
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            // NAS 专属高解析无损库看板
            HStack(spacing: 12) {
                Label("本地局域网直连", systemImage: "bolt.horizontal.fill")
                Spacer()
                Label("无损原盘音质", systemImage: "waveform")
                Spacer()
                Label("支持多音轨/分盘", systemImage: "opticaldisc.fill")
            }
            .font(ATMusicFont.appFont(11, .medium))
            .foregroundStyle(Color.atmusicComment)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.atmusicCard.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.atmusicLabel.opacity(0.12), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 16)
        }
    }

    private func discSectionHeader(discNumber: Int, songs: [Song], accentColor: Color = Color.atmusicAmber) -> some View {
        VStack(spacing: 8) {
            if discNumber > 1 {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.0), accentColor.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 11, weight: .bold))
                        Text("分盘分割")
                            .font(ATMusicFont.appFont(10, .semibold))
                    }
                    .foregroundStyle(accentColor.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(accentColor.opacity(0.25), lineWidth: 0.8)
                    )
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.4), accentColor.opacity(0.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                }
                .padding(.top, 14)
                .padding(.bottom, 6)
            }

            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(accentColor)
                    Text("CD \(discNumber)")
                        .font(ATMusicFont.appFont(14, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(accentColor.opacity(0.12))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(accentColor.opacity(0.25), lineWidth: 0.8)
                )

                Spacer()

                Text("\(songs.count) 首歌曲")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)

                Button {
                    if let firstIndex = sortedTracks.firstIndex(where: { $0.identityKey == songs.first?.identityKey }) {
                        ATMusicHaptics.tap()
                        player.play(songs: sortedTracks, startAt: firstIndex)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                        Text("播放本盘")
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - iPad 宽屏两栏全景专辑布局（对标 iPadOS Apple Music 专辑页规范）

    private var iPadAlbumLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            // 左栏：240pt 大封面 + NAS 专属属性看板 + 快捷播控
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: sortedTracks.first?.coverURL ?? coverURL, size: 240, cornerRadius: 24)
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)

                VStack(alignment: .leading, spacing: 8) {
                    // 群晖 NAS 专属琥珀流光徽标
                    HStack(spacing: 4) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("群晖 NAS · 私有无损库")
                            .font(ATMusicFont.appFont(11, .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.atmusicAmber.opacity(0.18))
                    .foregroundStyle(Color.atmusicAmber)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.atmusicAmber.opacity(0.35), lineWidth: 0.8)
                    )

                    Text(albumName)
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(3)

                    Text(artistName.isEmpty ? "未知歌手" : artistName)
                        .font(ATMusicFont.appFont(14, .medium))
                        .foregroundStyle(artistName.isEmpty ? Color.atmusicComment : Color.atmusicAmber)

                    HStack(spacing: 8) {
                        Text(atmusicSongCountText(sortedTracks.count))
                        if discGroups.count > 1 {
                            Text("· \(discGroups.count) CD 大碟")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                    }
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                }

                // NAS 专属高解析无损库看板
                HStack(spacing: 12) {
                    Label("本地局域网直连", systemImage: "bolt.horizontal.fill")
                    Spacer()
                    Label("无损原盘音质", systemImage: "waveform")
                    Spacer()
                    Label("支持多音轨/分盘", systemImage: "opticaldisc.fill")
                }
                .font(ATMusicFont.appFont(11, .medium))
                .foregroundStyle(Color.atmusicComment)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.atmusicCard.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.atmusicLabel.opacity(0.12), lineWidth: 0.5)
                        )
                )

                if !sortedTracks.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: sortedTracks, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            guard !sortedTracks.isEmpty else { return }
                            player.play(songs: sortedTracks.shuffled(), startAt: 0)
                        }
                        if discGroups.count > 1 {
                            GlassIconButton(systemName: "arrow.triangle.swap", size: 44, active: false) {
                                player.play(songs: sortedTracks, startAt: 0)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 260)
            .padding(.leading, 32)
            .padding(.top, 24)

            // 右栏：多 CD 分盘或双列自适应歌曲网格
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if discGroups.count > 1 {
                        ForEach(discGroups, id: \.disc) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                discSectionHeader(discNumber: group.disc, songs: group.songs)

                                LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                                    ForEach(Array(group.songs.enumerated()), id: \.element.identityKey) { index, song in
                                        let displayNo = (song.trackNumber >= 1 && song.trackNumber <= group.songs.count) ? song.trackNumber : (index + 1)
                                        let globalIndex = sortedTracks.firstIndex(of: song) ?? 0
                                        albumSongRow(song: song, index: globalIndex, playbackIndex: globalIndex, trackNumber: displayNo)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.primary.opacity(0.03))
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 12)
                        }
                    } else {
                        HStack {
                            Text("歌曲列表 (\(sortedTracks.count))")
                                .font(ATMusicFont.appFont(16, .bold))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                        }
                        .padding(.top, 4)

                        LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                            ForEach(Array(sortedTracks.enumerated()), id: \.element.identityKey) { index, song in
                                let displayNo = (song.trackNumber >= 1 && song.trackNumber <= sortedTracks.count) ? song.trackNumber : (index + 1)
                                albumSongRow(song: song, index: index, playbackIndex: index, trackNumber: displayNo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.03))
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 32)
                .padding(.bottom, 120)
            }
        }
    }

    private func load() async {
        guard synology.isLoggedIn else {
            isLoading = false
            errorMessage = "请先连接群晖 NAS"
            return
        }
        let seededTracks = matchingSongs(in: initialSongs)
        if !seededTracks.isEmpty {
            await MainActor.run {
                tracks = seededTracks
                isLoading = false
                errorMessage = nil
            }
        } else if !initialSongs.isEmpty {
            await MainActor.run {
                tracks = initialSongs
                isLoading = false
                errorMessage = nil
            }
        }
        // 优先使用专为 NAS 专辑打造的原生直读接口（自带严格双键保序与快速回包）
        let direct = await synology.albumSongs(albumName: albumName, artistName: artistName)
        if !direct.isEmpty {
            await MainActor.run {
                tracks = direct
                isLoading = false
                errorMessage = nil
            }
            return
        }

        // 若直读未命中，尝试利用搜索接口服务端匹配兜底
        let remote = try? await synology.searchAllVariants(keyword: albumName, limit: 300)
        var matches = matchingSongs(in: remote?.songs ?? [])
        if matches.isEmpty {
            let normalizedAlbum = normalize(albumName)
            matches = (remote?.songs ?? []).filter { normalize($0.album) == normalizedAlbum }
        }
        if !matches.isEmpty {
            await MainActor.run {
                tracks = matches
                isLoading = false
                errorMessage = nil
            }
            return
        }

        // 从已恢复的内存库缓存查找
        let cachedMatches = matchingSongs(in: synology.cachedLibrarySongs)
        if !cachedMatches.isEmpty {
            await MainActor.run {
                tracks = cachedMatches
                isLoading = false
                errorMessage = nil
            }
            return
        }

        // 全库兜底查询
        if let library = try? await synology.librarySongs(forceRefresh: false) {
            let libMatches = matchingSongs(in: library)
            if !libMatches.isEmpty {
                await MainActor.run {
                    tracks = libMatches
                    isLoading = false
                    errorMessage = nil
                }
                return
            }
        }

        await MainActor.run {
            isLoading = false
            if tracks.isEmpty {
                if !initialSongs.isEmpty {
                    tracks = initialSongs
                    errorMessage = nil
                } else {
                    errorMessage = "未找到专辑歌曲"
                }
            }
        }
    }

    private func matchingSongs(in songs: [Song]) -> [Song] {
        let normQueryAlbum = SongIdentityNormalizer.exactMetadata(albumName)
        let normQueryArtist = SongIdentityNormalizer.exactMetadata(artistName)
        guard !normQueryAlbum.isEmpty else { return [] }
        let albumMatches = songs.filter {
            let n = SongIdentityNormalizer.exactMetadata($0.album)
            return n == normQueryAlbum || n.contains(normQueryAlbum) || normQueryAlbum.contains(n)
        }
        guard !albumMatches.isEmpty else { return [] }
        guard !normQueryArtist.isEmpty else { return albumMatches }
        let artistMatches = albumMatches.filter {
            let actualArtist = SongIdentityNormalizer.exactMetadata($0.artists)
            let actualAlbumArtist = SongIdentityNormalizer.exactMetadata($0.albumArtist ?? "")
            return actualArtist.contains(normQueryArtist) ||
                   normQueryArtist.contains(actualArtist) ||
                   actualAlbumArtist.contains(normQueryArtist) ||
                   normQueryArtist.contains(actualAlbumArtist)
        }
        return artistMatches.isEmpty ? albumMatches : artistMatches
    }

    private func normalize(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
