import Foundation
import WatchConnectivity
import MediaPlayer

/// iOS 与 watchOS (Apple Watch) 协同通信服务
/// 负责将 iPhone / iPad 的播放状态、曲目信息、进度和队列实时同步至 Apple Watch，
/// 并响应来自手表端（包含数码表冠调节音量、切歌、播放/暂停、收藏等）的双向远程控制。
final class WatchSyncService: NSObject, WCSessionDelegate {
    static let shared = WatchSyncService()

    private var session: WCSession?
    private weak var player: PlayerManager?
    private var lastSentSnapshotKey: String?

    private override init() {
        super.init()
        setupSession()
    }

    func configure(player: PlayerManager) {
        self.player = player
        syncCurrentPlaybackState()
    }

    private func setupSession() {
        guard WCSession.isSupported() else { return }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    // MARK: - 发送数据至 Apple Watch
    func syncCurrentPlaybackState() {
        guard let session = session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            return
        }

        guard let player = player, let song = player.currentSong else {
            let emptyKey = "empty"
            let emptyContext: [String: Any] = [
                "isPlaying": false,
                "hasTrack": false
            ]
            if lastSentSnapshotKey != emptyKey {
                lastSentSnapshotKey = emptyKey
                try? session.updateApplicationContext(emptyContext)
            }
            return
        }

        // 仅用于判断"内容是否真的变化"，不含 currentTime 等持续变化的字段，避免高频重复发送
        let snapshotKey = [
            song.title, song.artist, song.album,
            String(max(player.duration, song.duration)),
            String(player.isPlaying),
            String(player.volume),
            song.coverURL?.absoluteString ?? "",
            song.source.displayName
        ].joined(separator: "|")

        let context: [String: Any] = [
            "hasTrack": true,
            "title": song.title,
            "artist": song.artist,
            "album": song.album,
            "duration": max(player.duration, song.duration),
            "currentTime": player.progress,
            "isPlaying": player.isPlaying,
            "volume": Double(player.volume),
            "coverURL": song.coverURL?.absoluteString ?? "",
            "source": song.source.displayName
        ]

        guard snapshotKey != lastSentSnapshotKey else { return }
        lastSentSnapshotKey = snapshotKey

        // 尝试发送即时消息（手表在前台时零延迟生效）
        if session.isReachable {
            session.sendMessage(context, replyHandler: nil, errorHandler: nil)
        }

        // 同时更新 ApplicationContext 确保手表后台唤醒即最新
        try? session.updateApplicationContext(context)
    }

    // MARK: - 响应来自 Apple Watch 的交互指令
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard let action = message["action"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let player = self.player else { return }

            switch action {
            case "togglePlayPause":
                player.togglePlayPause()
            case "play":
                if !player.isPlaying { player.togglePlayPause() }
            case "pause":
                if player.isPlaying { player.togglePlayPause() }
            case "next":
                player.nextTrack()
            case "previous":
                player.previousTrack()
            case "seek":
                if let target = message["position"] as? Double {
                    player.seek(to: target)
                }
            case "setVolume":
                if let vol = message["volume"] as? Double {
                    player.volume = Float(vol)
                }
            case "requestState":
                self.syncCurrentPlaybackState()
            default:
                break
            }

            self.syncCurrentPlaybackState()
        }
    }

    // MARK: - WCSessionDelegate 生命周期
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            syncCurrentPlaybackState()
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif
}
