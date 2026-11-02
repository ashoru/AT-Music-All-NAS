import SwiftUI

// MARK: - 歌曲信息扩展（歌手拆分、副标题、专辑对象）

extension Song {
    /// 解析所有参与歌手列表（多歌手合唱按常见分隔符拆分，保留原顺序并去重）
    var artistList: [String] {
        let raw = artists.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        var text = raw
        let delimiters = [
            " / ", " feat. ", " Feat. ", " ft. ", " Ft. ",
            " & ", "，", "、", "；", ";", "/", ","
        ]
        for delim in delimiters {
            text = text.replacingOccurrences(of: delim, with: "\u{001F}")
        }
        var seen = Set<String>()
        var result: [String] = []
        for part in text.components(separatedBy: "\u{001F}") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !seen.contains(trimmed) {
                seen.insert(trimmed)
                result.append(trimmed)
            }
        }
        return result.isEmpty ? [raw] : result
    }

    /// 歌手与专辑副标题文本，格式如 "歌手 · 专辑"
    var subtitleText: String {
        let trimmedArtist = artists.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [trimmedArtist, trimmedAlbum].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知歌曲" : parts.joined(separator: " · ")
    }

    /// 从当前歌曲构造专辑模型（用于跳转专辑页）
    var albumObject: Album? {
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlbum.isEmpty else { return nil }
        let albumID: String
        switch source {
        case .synology:
            albumID = "synology-\(trimmedAlbum)-\(artists)"
        case .netease:
            albumID = "netease-\(id)"
        default:
            albumID = "\(source.rawValue)-\(id)"
        }
        return Album(
            id: albumID,
            name: trimmedAlbum,
            artistName: artists,
            coverURL: coverURL,
            source: source,
            trackCount: nil
        )
    }
}

// MARK: - 歌手与专辑快捷跳转弹窗菜单（小框）

struct SongSubtitleMenu: View {
    let song: Song?
    let onSelectArtist: (String) -> Void
    let onSelectAlbum: (Album) -> Void
    let content: AnyView

    /// 自定义内容（trailing closure）构造
    init(
        song: Song?,
        onSelectArtist: @escaping (String) -> Void,
        onSelectAlbum: @escaping (Album) -> Void,
        @ViewBuilder content: () -> some View
    ) {
        self.song = song
        self.onSelectArtist = onSelectArtist
        self.onSelectAlbum = onSelectAlbum
        self.content = AnyView(content())
    }

    var body: some View {
        Menu {
            if let song {
                let artists = song.artistList
                ForEach(artists, id: \.self) { artist in
                    Button {
                        ATMusicHaptics.tap()
                        onSelectArtist(artist)
                    } label: {
                        Label(artist, systemImage: "person")
                    }
                }

                if let album = song.albumObject {
                    Divider()
                    Button {
                        ATMusicHaptics.tap()
                        onSelectAlbum(album)
                    } label: {
                        Label(album.name, systemImage: "opticaldisc")
                    }
                }
            }
        } label: {
            content
        }
        .menuStyle(.borderlessButton)
    }
}

extension SongSubtitleMenu {
    init(
        song: Song?,
        font: Font,
        color: Color,
        lineLimit: Int = 1,
        alignment: TextAlignment = .center,
        onSelectArtist: @escaping (String) -> Void,
        onSelectAlbum: @escaping (Album) -> Void
    ) {
        self.song = song
        self.onSelectArtist = onSelectArtist
        self.onSelectAlbum = onSelectAlbum
        self.content = AnyView(
            Text(song?.subtitleText ?? "未知歌曲")
                .font(font)
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(alignment)
        )
    }

    init(
        song: Song?,
        font: Font,
        foregroundStyle: AnyShapeStyle,
        lineLimit: Int = 1,
        alignment: TextAlignment = .center,
        onSelectArtist: @escaping (String) -> Void,
        onSelectAlbum: @escaping (Album) -> Void
    ) {
        self.song = song
        self.onSelectArtist = onSelectArtist
        self.onSelectAlbum = onSelectAlbum
        self.content = AnyView(
            Text(song?.subtitleText ?? "未知歌曲")
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(alignment)
        )
    }
}
