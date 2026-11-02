import Foundation
import SwiftUI
import WatchConnectivity

/// watchOS 手表端核心通信与状态管理器
/// 实时接收来自 iPhone / iPad 的播放状态，并通过 WatchConnectivity 发送控制指令
public final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    public static let shared = WatchSessionManager()

    @Published public var hasTrack: Bool = false
    @Published public var title: String = "未在播放"
    @Published public var artist: String = "AT Music"
    @Published public var album: String = ""
    @Published public var coverURL: URL? = nil
    @Published public var duration: Double = 1.0
    @Published public var currentTime: Double = 0.0
    @Published public var isPlaying: Bool = false
    @Published public var volume: Double = 0.5
    @Published public var source: String = "AT Music"
    @Published public var isFavorite: Bool = false

    private override init() {
        super.init()
        setupSession()
    }

    private func setupSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - 交互指令
    public func togglePlayPause() {
        sendCommand(["action": "togglePlayPause"])
        isPlaying.toggle()
    }

    public func nextTrack() {
        sendCommand(["action": "next"])
    }

    public func previousTrack() {
        sendCommand(["action": "previous"])
    }

    public func setVolume(_ newVolume: Double) {
        volume = min(max(newVolume, 0), 1)
        sendCommand(["action": "setVolume", "volume": volume])
    }

    public func toggleFavorite() {
        isFavorite.toggle()
        sendCommand(["action": "toggleFavorite"])
    }

    public func requestLatestState() {
        sendCommand(["action": "requestState"])
    }

    private func sendCommand(_ message: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    // MARK: - 接收数据
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.updateState(from: message)
        }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.updateState(from: applicationContext)
        }
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            requestLatestState()
        }
    }

    private func updateState(from data: [String: Any]) {
        if let has = data["hasTrack"] as? Bool {
            self.hasTrack = has
        }
        if let title = data["title"] as? String {
            self.title = title
        }
        if let artist = data["artist"] as? String {
            self.artist = artist
        }
        if let album = data["album"] as? String {
            self.album = album
        }
        if let urlStr = data["coverURL"] as? String, let url = URL(string: urlStr) {
            self.coverURL = url
        }
        if let dur = data["duration"] as? Double {
            self.duration = max(dur, 1.0)
        }
        if let cur = data["currentTime"] as? Double {
            self.currentTime = cur
        }
        if let playing = data["isPlaying"] as? Bool {
            self.isPlaying = playing
        }
        if let vol = data["volume"] as? Double {
            self.volume = vol
        }
        if let src = data["source"] as? String {
            self.source = src
        }
        if let fav = data["isFavorite"] as? Bool {
            self.isFavorite = fav
        }
    }
}
