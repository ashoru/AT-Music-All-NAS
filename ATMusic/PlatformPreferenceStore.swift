import SwiftUI
import Combine
import UIKit

/// 用户选择需要显示的平台。只控制入口可见性，不删除平台能力。
/// 平台歌单来源（原在已删除的 LibraryView.swift，PlatformPreferenceStore 仍在用，移到这里）。
enum LibraryProvider: String, CaseIterable, Identifiable, Hashable {
    case netease = "网易云音乐"
    case qq = "QQ音乐"
    case kugou = "酷狗音乐"
    case synology = "群晖 NAS"
    case subsonic = "Subsonic"
    case jellyfin = "Jellyfin"
    case webdav = "WebDAV"

    var id: String { rawValue }

    var tint: LinearGradient {
        switch self {
        case .netease:
            return LinearGradient(colors: [Color(red: 0.93, green: 0.22, blue: 0.16), Color(red: 0.80, green: 0.15, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .qq:
            return LinearGradient(colors: [Color(red: 0.15, green: 0.78, blue: 0.55), Color(red: 0.05, green: 0.58, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .kugou:
            return LinearGradient(colors: [Color(red: 0.12, green: 0.58, blue: 0.95), Color(red: 0.02, green: 0.32, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .synology:
            return LinearGradient(colors: [Color(red: 0.08, green: 0.45, blue: 0.85), Color(red: 0.02, green: 0.25, blue: 0.60)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .subsonic:
            return LinearGradient(colors: [Color(red: 0.26, green: 0.62, blue: 0.28), Color(red: 0.13, green: 0.42, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .jellyfin:
            return LinearGradient(colors: [Color(red: 0.65, green: 0.33, blue: 0.86), Color(red: 0.42, green: 0.16, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .webdav:
            return LinearGradient(colors: [Color(red: 0.55, green: 0.55, blue: 0.58), Color(red: 0.32, green: 0.32, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var icon: String {
        switch self {
        case .netease: return "cloud.fill"
        case .qq: return "play.rectangle.fill"
        case .kugou: return "music.note"
        case .synology: return "externaldrive.fill"
        case .subsonic: return "server.rack"
        case .jellyfin: return "play.tv.fill"
        case .webdav: return "folder.fill.badge.gearshape"
        }
    }

    var brandImageName: String? {
        switch self {
        case .netease: return "BrandNetease"
        case .qq: return "BrandQQ"
        case .kugou: return "BrandKugou"
        case .synology, .subsonic, .jellyfin, .webdav: return nil
        }
    }
}

private extension LibraryProvider {
    var songSource: SongSource {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        case .subsonic: return .subsonic
        case .jellyfin: return .jellyfin
        case .webdav: return .webdav
        }
    }
}

final class PlatformPreferenceStore: ObservableObject {
    static let shared = PlatformPreferenceStore()

    private static let key = "atmusic.enabledPlatforms.v1"
    private static let orderKey = "atmusic.platformOrder.v1"

    @Published private(set) var selectedRaw: Set<String>
    @Published var orderedRaw: [String]

    /// 仅隐藏页面顶部的平台切换控件，不影响平台启用状态或后台加载能力。
    static let hidePickerKey = "atmusic.hidePlatformPicker"

    var changes: AnyPublisher<Set<String>, Never> { $selectedRaw.eraseToAnyPublisher() }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        if saved.isEmpty {
            selectedRaw = Set(SearchProvider.allCases.map(\.rawValue))
        } else {
            selectedRaw = Set(saved.map(Self.migrateRawValue))
        }
        orderedRaw = UserDefaults.standard.stringArray(forKey: Self.orderKey)?
            .map(Self.migrateRawValue) ?? []
        normalize()
        normalizeOrder()
    }

    var enabledSearchProviders: [SearchProvider] {
        let list = orderedSearchProviders.filter { selectedRaw.contains($0.rawValue) }
        return list.isEmpty ? [.netease] : list
    }

    var enabledLibraryProviders: [LibraryProvider] {
        enabledSearchProviders.compactMap { provider in
            LibraryProvider(rawValue: provider.rawValue)
        }
    }

    var summaryText: String {
        enabledSearchProviders.map(\.rawValue).joined(separator: " / ")
    }

    func isEnabled(_ provider: SearchProvider) -> Bool {
        selectedRaw.contains(provider.rawValue)
    }

    func isEnabled(_ provider: LibraryProvider) -> Bool {
        isEnabled(provider.searchProvider)
    }

    func set(_ provider: SearchProvider, enabled: Bool) {
        if enabled {
            selectedRaw.insert(provider.rawValue)
        } else if selectedRaw.count > 1 {
            selectedRaw.remove(provider.rawValue)
        }
        normalize()
        save()
        objectWillChange.send()
        NotificationCenter.default.post(name: .atmusicPlatformPreferencesDidChange, object: nil)
    }

    func ensureVisible(_ provider: SearchProvider) -> SearchProvider {
        isEnabled(provider) ? provider : enabledSearchProviders.first ?? .netease
    }

    func ensureVisible(_ provider: LibraryProvider) -> LibraryProvider {
        isEnabled(provider) ? provider : enabledLibraryProviders.first ?? .netease
    }

    func resetToDefault() {
        selectedRaw = Set(SearchProvider.allCases.map(\.rawValue))
        resetOrder()
        save()
        objectWillChange.send()
        NotificationCenter.default.post(name: .atmusicPlatformPreferencesDidChange, object: nil)
    }

    func resetOrder() {
        orderedRaw = SearchProvider.allCases.map(\.rawValue)
        saveOrder()
        objectWillChange.send()
    }

    var orderedSearchProviders: [SearchProvider] {
        orderedRaw.compactMap(SearchProvider.init(rawValue:))
    }

    func moveProviders(from offsets: IndexSet, to destination: Int) {
        orderedRaw.move(fromOffsets: offsets, toOffset: destination)
        normalizeOrder()
        saveOrder()
        objectWillChange.send()
    }

    private func normalize() {
        let allowed = Set(SearchProvider.allCases.map(\.rawValue))
        selectedRaw = selectedRaw.intersection(allowed)
        if selectedRaw.isEmpty {
            selectedRaw = [SearchProvider.netease.rawValue]
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(selectedRaw), forKey: Self.key)
    }

    private func normalizeOrder() {
        let defaults = SearchProvider.allCases.map(\.rawValue)
        var result = orderedRaw.filter { defaults.contains($0) }
        for raw in defaults where !result.contains(raw) {
            result.append(raw)
        }
        orderedRaw = result
    }

    private func saveOrder() {
        UserDefaults.standard.set(orderedRaw, forKey: Self.orderKey)
    }

    private static func migrateRawValue(_ raw: String) -> String {
        raw == "网易云" ? SearchProvider.netease.rawValue : raw
    }
}

extension LibraryProvider {
    var searchProvider: SearchProvider {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        case .subsonic: return .subsonic
        case .jellyfin: return .jellyfin
        case .webdav: return .webdav
        }
    }
}

extension SearchProvider {
    var songSource: SongSource {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        case .subsonic: return .subsonic
        case .jellyfin: return .jellyfin
        case .webdav: return .webdav
        }
    }
}

extension SongSource {
    var searchProvider: SearchProvider? {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        case .subsonic: return .subsonic
        case .jellyfin: return .jellyfin
        case .webdav: return .webdav
        case .local: return nil
        }
    }
}

struct PlatformPreferencePicker: View {
    @ObservedObject private var store = PlatformPreferenceStore.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(store.orderedSearchProviders) { provider in
                let isEnabled = store.isEnabled(provider)
                Button {
                    ATMusicHaptics.select()
                    store.set(provider, enabled: !isEnabled)
                } label: {
                    HStack(spacing: 12) {
                        if let imageName = provider.brandImageName {
                            Image(imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                        } else {
                            Image(systemName: provider.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 26, height: 26)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(provider.rawValue))
                                .font(ATMusicFont.appFont(14, .semibold))
                                .foregroundStyle(Color.atmusicLabel)
                            Text(LocalizedStringKey(isEnabled ? "已显示" : "已隐藏"))
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        Spacer()
                        Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(isEnabled ? Color.atmusicAmber : Color.atmusicComment.opacity(0.35))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
