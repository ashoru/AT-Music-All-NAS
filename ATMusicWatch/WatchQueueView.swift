import SwiftUI

/// watchOS 待播队列快捷查看视图
public struct WatchQueueView: View {
    @ObservedObject private var manager = WatchSessionManager.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        List {
            Section("正在播放") {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(manager.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                }
            }

            Section("快捷控制") {
                Button {
                    manager.previousTrack()
                } label: {
                    Label("上一首", systemImage: "backward.fill")
                }

                Button {
                    manager.nextTrack()
                } label: {
                    Label("下一首", systemImage: "forward.fill")
                }

                Button {
                    manager.toggleFavorite()
                } label: {
                    Label(manager.isFavorite ? "取消收藏" : "收藏本曲", systemImage: manager.isFavorite ? "heart.slash" : "heart.fill")
                }
            }
        }
        .navigationTitle("播放队列")
    }
}
