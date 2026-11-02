import SwiftUI

/// 移歌 / 复制目标选择器（阶段 2/3 共用）：本地 / 网易 / NAS 三组。
/// QQ、酷狗不在目标里（平台加歌接口未封装）；调用方对 QQ/酷狗来源
/// 另提供「转存本地」按钮（onCreateLocalCopy），不要把歌丢进一个写不进去的目标。
struct PlaylistMoveTargetSheet: View {
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @Environment(\.dismiss) private var dismiss

    let songs: [Song]
    let title: String
    let actionLabel: String
    var onSelect: (PlaylistEditTarget) async -> Void
    var onCreateLocalCopy: (() async -> Void)? = nil

    @State private var nasPlaylists: [Playlist] = []
    @State private var message: String?

    var body: some View {
        ATMusicNavigationStack {
            List {
                Section("本地歌单") {
                    if localStore.playlists.isEmpty {
                        Text("还没有本地歌单，先去音乐库新建一个吧")
                            .foregroundStyle(Color.atmusicComment)
                    } else {
                        ForEach(localStore.playlists) { playlist in
                            targetRow(
                                name: playlist.name,
                                countText: atmusicLocalSongCountText(playlist.songs.count),
                                coverURL: playlist.coverURL ?? playlist.songs.first?.coverURL
                            ) {
                                await onSelect(.local(playlist.id))
                                dismiss()
                            }
                        }
                    }
                }

                Section("网易歌单") {
                    if !auth.isLoggedIn {
                        Text("登录网易云后可移入云端歌单")
                            .foregroundStyle(Color.atmusicComment)
                    } else if auth.playlists.isEmpty {
                        Text("暂无网易歌单")
                            .foregroundStyle(Color.atmusicComment)
                    } else {
                        ForEach(auth.playlists) { playlist in
                            targetRow(
                                name: playlist.name,
                                countText: atmusicSongCountText(playlist.trackCount),
                                coverURL: playlist.coverURL
                            ) {
                                await onSelect(.netease(playlist))
                                dismiss()
                            }
                        }
                    }
                }

                if synology.isLoggedIn {
                    Section("NAS 歌单") {
                        if nasPlaylists.isEmpty {
                            Text("暂无 NAS 歌单")
                                .foregroundStyle(Color.atmusicComment)
                        } else {
                            ForEach(nasPlaylists) { playlist in
                                targetRow(
                                    name: playlist.name,
                                    countText: atmusicSongCountText(playlist.trackCount),
                                    coverURL: playlist.coverURL
                                ) {
                                    await onSelect(.nas(playlist))
                                    dismiss()
                                }
                            }
                        }
                    }
                }

                if let onCreateLocalCopy {
                    Section {
                        Button {
                            Task {
                                await onCreateLocalCopy()
                                dismiss()
                            }
                        } label: {
                            Label("转存为新的本地歌单", systemImage: "square.and.arrow.down")
                        }
                    } footer: {
                        Text("原歌单不动，另外存一份到本地，之后可在本地歌单里自由编辑。")
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicSage)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            if synology.isLoggedIn {
                nasPlaylists = (try? await SynologyAPI.shared.allPlaylists()) ?? []
            }
        }
    }

    private func targetRow(name: String, countText: String, coverURL: URL?, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                CoverImage(url: coverURL, size: 38, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Text(countText)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                Text(actionLabel)
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicAmber)
            }
        }
    }
}
