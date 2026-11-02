import Foundation

/// 旧版“强制 120Hz”设置的迁移器。
/// 现在不再创建 CADisplayLink，也不再请求固定帧率；iOS / ProMotion 全程自适应。
final class HighRefreshKeeper {
    static let shared = HighRefreshKeeper()
    static let defaultsKey = "atmusic.enableHighRefresh"

    private init() {}

    static func registerDefaults() {
        // 明确关闭旧版强制高刷语义。
        UserDefaults.standard.register(defaults: [defaultsKey: false])
        UserDefaults.standard.set(false, forKey: defaultsKey)
    }

    func configureFromDefaults() {
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
    }
}
