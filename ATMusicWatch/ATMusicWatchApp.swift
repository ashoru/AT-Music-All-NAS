import SwiftUI

/// watchOS Apple Watch 应用入口点
@main
public struct ATMusicWatchApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchNowPlayingView()
            }
        }
    }
}
