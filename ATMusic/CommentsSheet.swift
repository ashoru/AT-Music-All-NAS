import SwiftUI

// MARK: - 相对时间

func atmusicRelativeTime(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return NSLocalizedString("刚刚", comment: "") }
    if interval < 3600 { return String(format: NSLocalizedString("%d 分钟前", comment: ""), Int(interval / 60)) }
    if interval < 86400 { return String(format: NSLocalizedString("%d 小时前", comment: ""), Int(interval / 3600)) }
    if interval < 86400 * 30 { return String(format: NSLocalizedString("%d 天前", comment: ""), Int(interval / 86400)) }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}


// MARK: - 评论区

struct CommentsSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    let song: Song

    @State private var page: NetEaseAPI.SongCommentPage?
    @State private var selectedCommentTab: CommentTab = .latest
    @State private var qqHotComments: [SongComment] = []
    @State private var qqComments: [SongComment] = []
    @State private var qqTotal = 0
    @State private var qqPageNum = 0
    @State private var kugouComments: [SongComment] = []
    @State private var kugouHotComments: [SongComment] = []
    @State private var kugouTotal = 0
    @State private var kugouPageNum = 1
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var offset = 0

    private let limit = 30
    /// QQ 音乐每页条数（接口单页上限 25）
    private let qqPageSize = 25

    private enum CommentTab: String, CaseIterable, Identifiable {
        case hot = "热门"
        case latest = "最新"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            ATMusicNavigationStack {
                Group {
                    if loading {
                        LoadingStateView()
                    } else if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await load(reset: true) }
                        }
                    } else if song.source == .kugou {
                        kugouCommentList
                    } else if song.source == .qq {
                        qqCommentList
                    } else if let page {
                        if page.hot.isEmpty && page.comments.isEmpty {
                            EmptyStateView(icon: "bubble.left", text: "暂无评论")
                        } else {
                            neteaseCommentList(page)
                        }
                    }
                }
                .navigationTitle("评论")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load(reset: true) }
    }

    private func neteaseCommentList(_ page: NetEaseAPI.SongCommentPage) -> some View {
        List {
            if !page.hot.isEmpty {
                Picker("评论分类", selection: $selectedCommentTab) {
                    ForEach(CommentTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
            } else if !page.comments.isEmpty {
                Picker("评论分类", selection: $selectedCommentTab) {
                    Text("最新").tag(CommentTab.latest)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section(selectedCommentTab == .hot ? "热门评论" : "最新评论") {
                ForEach(selectedCommentTab == .hot ? page.hot : page.comments) { comment in
                        CommentRow(comment: comment)
                            .listRowBackground(Color.clear)
                }
            }
            if selectedCommentTab == .latest && page.comments.count >= limit {
                Section {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Text("加载更多")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .atmusicScrollContentBackgroundHidden()
    }

    private func load(reset: Bool) async {
        if reset {
            offset = 0
            page = nil
            selectedCommentTab = .latest
            qqHotComments = []
            qqComments = []
            qqTotal = 0
            qqPageNum = 0
            kugouComments = []
            kugouHotComments = []
            kugouTotal = 0
            kugouPageNum = 1
            loading = true
        }
        errorMessage = nil
        do {
            if song.source == .kugou {
                let mixSongID = song.kugouAlbumAudioId ?? ""
                let result = try await KugouMusicAPI.shared.comments(
                    mixSongID: mixSongID,
                    hash: song.kugouHash,
                    page: kugouPageNum,
                    limit: limit
                )
                if reset {
                    kugouHotComments = result.hot
                    kugouComments = result.comments
                } else {
                    kugouComments.append(contentsOf: result.comments)
                }
                kugouTotal = result.total
                loading = false
                return
            } else if song.source == .qq {
                let result = try await QQMusicAPI.shared.comments(songID: song.id, limit: qqPageSize, pagenum: qqPageNum)
                if reset {
                    qqHotComments = result.hot
                    qqComments = result.comments
                } else {
                    qqComments.append(contentsOf: result.comments)
                }
                qqTotal = result.total
            } else {
                let result = try await NetEaseAPI.shared.songComments(id: song.id, limit: limit, offset: offset)
                if reset {
                    page = result
                } else if var current = page {
                    current.comments.append(contentsOf: result.comments)
                    page = current
                }
            }
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    /// QQ 音乐评论列表（分页加载更多）
    private var qqCommentList: some View {
        Group {
            if qqHotComments.isEmpty && qqComments.isEmpty {
                EmptyStateView(icon: "bubble.left", text: "暂无评论")
            } else {
                List {
                    Picker("评论分类", selection: $selectedCommentTab) {
                        ForEach(CommentTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    Section(selectedCommentTab == .hot ? "热门评论" : "最新评论") {
                        ForEach(selectedCommentTab == .hot ? qqHotComments : qqComments) { comment in
                            CommentRow(comment: comment)
                                .listRowBackground(Color.clear)
                        }
                    }
                    if selectedCommentTab == .latest && (qqTotal <= 0 || qqComments.count < qqTotal) {
                        Section {
                            Button {
                                Task { await loadQQMore() }
                            } label: {
                                Text("加载更多")
                                    .font(ATMusicFont.appFont(14, .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .atmusicScrollContentBackgroundHidden()
            }
        }
    }

    /// QQ 评论翻页
    private func loadQQMore() async {
        qqPageNum += 1
        await load(reset: false)
    }

    private var kugouCommentList: some View {
        Group {
            if kugouHotComments.isEmpty && kugouComments.isEmpty {
                EmptyStateView(icon: "bubble.left", text: "暂无评论")
            } else {
                List {
                    Picker("评论分类", selection: $selectedCommentTab) {
                        ForEach(CommentTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    Section(selectedCommentTab == .hot ? "热门评论" : "最新评论") {
                        ForEach(selectedCommentTab == .hot ? kugouHotComments : kugouComments) { comment in
                            CommentRow(comment: comment)
                                .listRowBackground(Color.clear)
                        }
                    }
                    if selectedCommentTab == .latest && (kugouTotal <= 0 || kugouComments.count < kugouTotal) {
                        Section {
                            Button {
                                kugouPageNum += 1
                                Task { await load(reset: false) }
                            } label: {
                                Text("加载更多")
                                    .font(ATMusicFont.appFont(14, .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .atmusicScrollContentBackgroundHidden()
            }
        }
    }

    private func loadMore() async {
        offset += limit
        await load(reset: false)
    }
}

// MARK: - 评论行

struct CommentRow: View {
    @EnvironmentObject private var theme: ThemeStore
    let comment: SongComment

    var body: some View {
        let _ = theme.accent
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: comment.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .background(Color.atmusicGlassFill, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(comment.nickname)
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                    if comment.isHot {
                        Text("热评")
                            .font(ATMusicFont.appFont(9, .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(LinearGradient.atmusicAccent, in: Capsule())
                    }
                    Spacer()
                    Text(atmusicRelativeTime(comment.time))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment.opacity(0.8))
                }
                Text(comment.content)
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Label("\(comment.likedCount)", systemImage: "heart")
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(Color.atmusicComment)
                        .labelStyle(.trailingIcon)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// 图标在文字后面
extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
