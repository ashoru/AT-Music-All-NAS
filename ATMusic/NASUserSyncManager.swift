import Foundation
import SwiftUI
import Combine
import UIKit

// MARK: - 用户数据同步模型

/// 用户同步数据结构包（跨设备全量镜像与快照）
struct NASUserProfile: Codable {
    var version: Int = 1
    var deviceId: String
    var deviceName: String
    var updatedAt: Date

    // 1. 设置偏好
    var settings: NASUserSettings

    // 2. 播放历史
    var history: [Song]

    // 3. 本地自建歌单
    var localPlaylists: [LocalPlaylist]

    // 4. 红心收藏
    var qqFavorites: [Song]
    var neteaseFavorites: [Song]
    var kugouFavorites: [Song]
    var synologyFavorites: [Song]
    var favoritePlaylists: [Playlist]

    // 5. 归档账本
    var archivedKeys: [String]
}

struct NASUserSettings: Codable {
    var uiStyle: String?
    var themeMode: String?
    var language: String?
    var homeWallpaperBlur: Double?
    var tabLabelsVisible: Bool?
    var audioQuality: String?
    var thirdPartyQuality: String?
    var thirdPartyQualityDownload: String?
    var enabledPlatforms: [String]?
    var platformOrder: [String]?
    var hidePlatformPicker: Bool?
    var unblockGlobalEnabled: Bool?
    var mixesWithOthers: Bool?
    var showThirdPartyVIPNotice: Bool?
    var showSongVIPBadge: Bool?
    var nasUploadRoot: String?
    var nasTranscodeOnCellular: Bool?
    var skipIntro: Int?
    var skipOutro: Int?
}

struct NASManifest: Codable {
    var version: Int = 1
    var lastUpdatedDeviceId: String
    var lastUpdatedDeviceName: String
    var updatedAt: Date
    var syncCount: Int
}

// MARK: - 群晖 NAS 用户数据同步与云端灾备核心管理器

@MainActor
final class NASUserSyncManager: ObservableObject {
    static let shared = NASUserSyncManager()

    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?
    @Published var lastSyncDevice: String?
    @Published var autoSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSyncEnabled, forKey: "atmusic.nas.autoSyncEnabled")
        }
    }
    @Published var syncStatusMessage: String = ""

    private let syncFolder = "/music/ATMusic/.sync"
    private let profileFile = "user_profile.json"
    private let manifestFile = "sync_manifest.json"

    private var syncDebounceTask: Task<Void, Never>?

    private var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "device-\(UUID().uuidString.prefix(8))"
    }

    private var deviceName: String {
        UIDevice.current.name
    }

    var formattedLastSyncTime: String {
        guard let date = lastSyncDate else { return "尚未同步" }
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "昨天 HH:mm"
        } else {
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }
        let timeStr = formatter.string(from: date)
        if let dev = lastSyncDevice, !dev.isEmpty {
            return "\(timeStr) · \(dev)"
        }
        return timeStr
    }


    private var localPlaybackHistory: [Song] {
        if let data = UserDefaults.standard.data(forKey: "atmusic.history"),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            return list
        }
        return []
    }

    private func mergePlaybackHistory(remote: [Song]) {
        let local = localPlaybackHistory
        var map: [String: Song] = [:]
        var orderedKeys: [String] = []
        for s in local {
            if map[s.identityKey] == nil {
                map[s.identityKey] = s
                orderedKeys.append(s.identityKey)
            }
        }
        for s in remote {
            if map[s.identityKey] == nil {
                map[s.identityKey] = s
                orderedKeys.append(s.identityKey)
            }
        }
        let merged = Array(orderedKeys.prefix(50).compactMap { map[$0] })
        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: "atmusic.history")
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "atmusic.nas.autoSyncEnabled") == nil {
            self.autoSyncEnabled = true
        } else {
            self.autoSyncEnabled = defaults.bool(forKey: "atmusic.nas.autoSyncEnabled")
        }

        let ts = defaults.double(forKey: "atmusic.nas.lastSyncDate")
        if ts > 0 {
            self.lastSyncDate = Date(timeIntervalSince1970: ts)
        }
        self.lastSyncDevice = defaults.string(forKey: "atmusic.nas.lastSyncDevice")
    }

    // MARK: - 备份至 NAS

    @discardableResult
    func backupToNAS(isManual: Bool = false) async -> Bool {
        guard SynologyAPI.shared.isLoggedIn else {
            if isManual {
                ToastCenter.shared.show("请先在「我的」或设置中登录群晖 NAS")
            }
            return false
        }
        guard !isSyncing else { return false }
        isSyncing = true
        syncStatusMessage = "正在备份数据至群晖 NAS..."
        defer { isSyncing = false }

        let defaults = UserDefaults.standard
        let currentSettings = NASUserSettings(
            uiStyle: defaults.string(forKey: "atmusic.uiStyle"),
            themeMode: defaults.string(forKey: "atmusic.themeMode"),
            language: defaults.string(forKey: "atmusic.language"),
            homeWallpaperBlur: defaults.double(forKey: "atmusic.homeWallpaperBlur"),
            tabLabelsVisible: defaults.bool(forKey: "atmusic.tabLabelsVisible"),
            audioQuality: defaults.string(forKey: "atmusic.audioQuality"),
            thirdPartyQuality: defaults.string(forKey: "atmusic.thirdPartyQuality"),
            thirdPartyQualityDownload: defaults.string(forKey: ThirdPartyAudioQuality.downloadStorageKey),
            enabledPlatforms: defaults.stringArray(forKey: "atmusic.enabledPlatforms.v1"),
            platformOrder: defaults.stringArray(forKey: "atmusic.platformOrder.v1"),
            hidePlatformPicker: defaults.bool(forKey: PlatformPreferenceStore.hidePickerKey),
            unblockGlobalEnabled: defaults.bool(forKey: "atmusic.unblock.globalEnabled"),
            mixesWithOthers: defaults.bool(forKey: "atmusic.audio.mixothers.v1"),
            showThirdPartyVIPNotice: defaults.bool(forKey: "atmusic.showThirdPartyVIPNotice"),
            showSongVIPBadge: defaults.bool(forKey: "atmusic.showSongVIPBadge"),
            nasUploadRoot: defaults.string(forKey: "atmusic.nas.uploadRoot"),
            nasTranscodeOnCellular: defaults.bool(forKey: "atmusic.nas.transcodeOnCellular"),
            skipIntro: defaults.integer(forKey: "atmusic.player.skipIntro"),
            skipOutro: defaults.integer(forKey: "atmusic.player.skipOutro")
        )

        let profile = NASUserProfile(
            version: 1,
            deviceId: deviceId,
            deviceName: deviceName,
            updatedAt: Date(),
            settings: currentSettings,
            history: localPlaybackHistory,
            localPlaylists: LocalLibraryStore.shared.playlists,
            qqFavorites: FavoritesStore.shared.qqFavoriteSongs,
            neteaseFavorites: FavoritesStore.shared.neteaseFavoriteSongs,
            kugouFavorites: FavoritesStore.shared.kugouFavoriteSongs,
            synologyFavorites: FavoritesStore.shared.synologyFavoriteSongs,
            favoritePlaylists: FavoritePlaylistStore.shared.playlists,
            archivedKeys: Array(NASArchiveStore.shared.archivedIdentityKeys)
        )

        let currentCount = defaults.integer(forKey: "atmusic.nas.syncCount") + 1
        defaults.set(currentCount, forKey: "atmusic.nas.syncCount")

        let manifest = NASManifest(
            version: 1,
            lastUpdatedDeviceId: deviceId,
            lastUpdatedDeviceName: deviceName,
            updatedAt: Date(),
            syncCount: currentCount
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        guard let profileData = try? encoder.encode(profile),
              let manifestData = try? encoder.encode(manifest) else {
            if isManual { ToastCenter.shared.show("用户数据打包编码失败") }
            return false
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempProfileURL = tempDir.appendingPathComponent("sync_profile_\(UUID().uuidString).json")
        let tempManifestURL = tempDir.appendingPathComponent("sync_manifest_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: tempProfileURL)
            try? FileManager.default.removeItem(at: tempManifestURL)
        }

        do {
            try profileData.write(to: tempProfileURL)
            try manifestData.write(to: tempManifestURL)

            _ = try await SynologyAPI.shared.uploadFileToNAS(
                localFileURL: tempProfileURL,
                destinationFolder: syncFolder,
                filename: profileFile,
                mimeType: "application/json"
            )
            _ = try await SynologyAPI.shared.uploadFileToNAS(
                localFileURL: tempManifestURL,
                destinationFolder: syncFolder,
                filename: manifestFile,
                mimeType: "application/json"
            )

            let now = Date()
            lastSyncDate = now
            lastSyncDevice = deviceName
            defaults.set(now.timeIntervalSince1970, forKey: "atmusic.nas.lastSyncDate")
            defaults.set(deviceName, forKey: "atmusic.nas.lastSyncDevice")

            syncStatusMessage = "已同步至群晖 NAS"
            ATMusicLogger.shared.log("☁️ 用户全量数据成功备份至 NAS：\(syncFolder)/\(profileFile)", level: .info)
            if isManual {
                ToastCenter.shared.show("已成功备份数据至群晖 NAS")
                ATMusicHaptics.success()
            }
            return true
        } catch {
            syncStatusMessage = "备份失败：\(error.localizedDescription)"
            ATMusicLogger.shared.log("❌ 用户数据备份到 NAS 失败：\(error.localizedDescription)", level: .error)
            if isManual {
                ToastCenter.shared.show("备份失败：\(error.localizedDescription)")
            }
            return false
        }
    }

    // MARK: - 从 NAS 恢复并合并

    @discardableResult
    func restoreFromNAS(isManual: Bool = false) async -> Bool {
        guard SynologyAPI.shared.isLoggedIn else {
            if isManual { ToastCenter.shared.show("请先在「我的」或设置中登录群晖 NAS") }
            return false
        }
        guard !isSyncing else { return false }
        isSyncing = true
        syncStatusMessage = "正在从群晖 NAS 恢复并同步数据..."
        defer { isSyncing = false }

        do {
            let data = try await SynologyAPI.shared.downloadFileFromNAS(path: "\(syncFolder)/\(profileFile)")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profile = try decoder.decode(NASUserProfile.self, from: data)

            // 1. 合并播放历史
            mergePlaybackHistory(remote: profile.history)

            // 2. 合并本地自建歌单
            LocalLibraryStore.shared.mergePlaylists(profile.localPlaylists)

            // 3. 合并全平台红心收藏
            FavoritesStore.shared.mergeRemoteFavorites(
                qq: profile.qqFavorites,
                netease: profile.neteaseFavorites,
                kugou: profile.kugouFavorites,
                synology: profile.synologyFavorites
            )

            // 4. 合并在线收藏歌单
            FavoritePlaylistStore.shared.mergeRemotePlaylists(profile.favoritePlaylists)

            // 5. 合并 NAS 归档账本
            NASArchiveStore.shared.mergeRemoteArchivedKeys(profile.archivedKeys)

            // 6. 恢复设置（若手动恢复，或云端是其他设备更新且较新）
            let defaults = UserDefaults.standard
            let s = profile.settings
            if let v = s.uiStyle { defaults.set(v, forKey: "atmusic.uiStyle"); ThemeStore.shared.setUIStyle(ATMusicUIStyle(rawValue: v) ?? .nativeClean) }
            if let v = s.themeMode { defaults.set(v, forKey: "atmusic.themeMode") }
            if let v = s.homeWallpaperBlur { defaults.set(v, forKey: "atmusic.homeWallpaperBlur") }
            if let v = s.tabLabelsVisible { defaults.set(v, forKey: "atmusic.tabLabelsVisible") }
            if let v = s.audioQuality { defaults.set(v, forKey: "atmusic.audioQuality") }
            if let v = s.thirdPartyQuality { defaults.set(v, forKey: "atmusic.thirdPartyQuality") }
            if let v = s.thirdPartyQualityDownload { defaults.set(v, forKey: ThirdPartyAudioQuality.downloadStorageKey) }
            if let v = s.enabledPlatforms { defaults.set(v, forKey: "atmusic.enabledPlatforms.v1") }
            if let v = s.platformOrder { defaults.set(v, forKey: "atmusic.platformOrder.v1") }
            if let v = s.hidePlatformPicker { defaults.set(v, forKey: PlatformPreferenceStore.hidePickerKey) }
            if let v = s.unblockGlobalEnabled { defaults.set(v, forKey: "atmusic.unblock.globalEnabled") }
            if let v = s.mixesWithOthers { defaults.set(v, forKey: "atmusic.audio.mixothers.v1") }
            if let v = s.showThirdPartyVIPNotice { defaults.set(v, forKey: "atmusic.showThirdPartyVIPNotice") }
            if let v = s.showSongVIPBadge { defaults.set(v, forKey: "atmusic.showSongVIPBadge") }
            if let v = s.nasUploadRoot { defaults.set(v, forKey: "atmusic.nas.uploadRoot") }
            if let v = s.nasTranscodeOnCellular { defaults.set(v, forKey: "atmusic.nas.transcodeOnCellular") }
            if let v = s.skipIntro { defaults.set(v, forKey: "atmusic.player.skipIntro") }
            if let v = s.skipOutro { defaults.set(v, forKey: "atmusic.player.skipOutro") }

            let now = Date()
            lastSyncDate = profile.updatedAt
            lastSyncDevice = profile.deviceName
            defaults.set(profile.updatedAt.timeIntervalSince1970, forKey: "atmusic.nas.lastSyncDate")
            defaults.set(profile.deviceName, forKey: "atmusic.nas.lastSyncDevice")

            syncStatusMessage = "已从群晖 NAS 恢复 (\(profile.deviceName))"
            ATMusicLogger.shared.log("☁️ 成功从 NAS 恢复用户数据：已同步歌单、收藏、历史与设置（来源设备：\(profile.deviceName)）", level: .info)
            if isManual {
                ToastCenter.shared.show("已从 NAS 恢复最新数据（来自 \(profile.deviceName)）")
                ATMusicHaptics.success()
            }
            return true
        } catch {
            syncStatusMessage = "恢复失败：\(error.localizedDescription)"
            ATMusicLogger.shared.log("❌ 从 NAS 恢复数据失败：\(error.localizedDescription)", level: .error)
            if isManual {
                ToastCenter.shared.show("恢复失败：未找到有效备份或网络超时")
            }
            return false
        }
    }

    // MARK: - 触发调度

    func checkAndAutoSyncOnLaunch() {
        guard autoSyncEnabled, SynologyAPI.shared.isLoggedIn else { return }
        Task { @MainActor in
            do {
                let manifestData = try await SynologyAPI.shared.downloadFileFromNAS(path: "\(syncFolder)/\(manifestFile)")
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(NASManifest.self, from: manifestData)

                let localTimestamp = UserDefaults.standard.double(forKey: "atmusic.nas.lastSyncDate")
                let remoteTimestamp = manifest.updatedAt.timeIntervalSince1970

                if remoteTimestamp > localTimestamp + 10 && manifest.lastUpdatedDeviceId != deviceId {
                    // 云端由其他设备更新且比本地新，自动拉取合并
                    ATMusicLogger.shared.log("☁️ 检测到群晖 NAS 存在来自 \(manifest.lastUpdatedDeviceName) 的更新数据，开始静默合并...", level: .info)
                    _ = await restoreFromNAS(isManual: false)
                } else if localTimestamp == 0 {
                    // 本机尚未同步过，拉取一次合并
                    _ = await restoreFromNAS(isManual: false)
                }
            } catch {
                // 如果云端还没有同步文件，执行当前设备首次同步备份
                ATMusicLogger.shared.log("☁️ 云端尚无同步记录，执行当前设备首次同步备份", level: .info)
                _ = await backupToNAS(isManual: false)
            }
        }
    }

    /// 自动同步的最小间隔：短时间内多次下载触发的自动备份会被合并到下一个允许的时间点，
    /// 而不是逐次整包上传。用户手动点击同步、以及进入后台的"最后机会"同步均不受此限制。
    private static let minAutoSyncInterval: TimeInterval = 30

    func scheduleAutoSync() {
        guard autoSyncEnabled, SynologyAPI.shared.isLoggedIn else { return }
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8秒防抖
            guard !Task.isCancelled else { return }

            if let last = lastSyncDate {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed < Self.minAutoSyncInterval {
                    let remaining = Self.minAutoSyncInterval - elapsed
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                }
            }
            _ = await backupToNAS(isManual: false)
        }
    }

    func syncOnBackground() {
        guard autoSyncEnabled, SynologyAPI.shared.isLoggedIn else { return }
        Task { @MainActor in
            _ = await backupToNAS(isManual: false)
        }
    }
}
