import SwiftUI

/// watchOS Apple Watch 专属「正在播放」界面
/// 遵循 Apple Watch 核心人机界面指南（HIG），支持数码表冠（Digital Crown）旋转调音量、触觉反馈与大按键交互
public struct WatchNowPlayingView: View {
    @ObservedObject private var manager = WatchSessionManager.shared
    @State private var crownVolume: Double = 0.5
    @State private var showQueue = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                // 顶部音源标识
                HStack {
                    Text(manager.source)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.2)))
                    Spacer()
                    Button {
                        manager.toggleFavorite()
                    } label: {
                        Image(systemName: manager.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 14))
                            .foregroundStyle(manager.isFavorite ? .red : .gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                // 专辑封面与歌曲信息
                HStack(spacing: 10) {
                    if let url = manager.coverURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.gray.opacity(0.3))
                                    .overlay(Image(systemName: "music.note").font(.system(size: 14)))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.gray.opacity(0.3))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "music.note").font(.system(size: 14)))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(manager.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                // 播放进度指示条
                VStack(spacing: 3) {
                    ProgressView(value: min(max(manager.currentTime / manager.duration, 0), 1))
                        .tint(.orange)

                    HStack {
                        Text(formatTime(manager.currentTime))
                        Spacer()
                        Text(formatTime(manager.duration))
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                }

                // 核心播放按键组
                HStack(spacing: 18) {
                    Button {
                        manager.previousTrack()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        manager.togglePlayPause()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 48, height: 48)

                            Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: manager.isPlaying ? 0 : 1.5)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        manager.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)

                // 数码表冠（Digital Crown）音量提示
                HStack(spacing: 6) {
                    Image(systemName: "digitalcrown.horizontal.press.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("旋转表冠调节音量 (\(Int(crownVolume * 100))%)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 6)
        }
        .focusable()
        .digitalCrownRotation(
            $crownVolume,
            from: 0.0,
            through: 1.0,
            by: 0.05,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownVolume) { _, newVol in
            manager.setVolume(newVol)
        }
        .onAppear {
            crownVolume = manager.volume
            manager.requestLatestState()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
