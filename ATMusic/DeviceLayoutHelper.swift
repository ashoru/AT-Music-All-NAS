import SwiftUI
import UIKit

/// 设备形态与自适应布局辅助工具
/// 确保 iPadOS 享有媲美 Apple Music 的大屏多栏网格体验，同时 100% 保持 iPhone 原有界面的紧凑设计。
public struct DeviceLayoutHelper {
    /// 是否为 iPad 设备形态
    public static var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 当前环境是否应当使用 iPad 宽屏多栏/侧栏布局
    /// 仅在物理 iPad 且处于 regular 尺寸类（全屏或大分屏）时生效；
    /// 当处于 iPad 1/3 窄分屏（Slide Over / 紧凑模式）或 iPhone 时，自动回退到原生单栏 TabView 体验。
    public static func isIPadRegular(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isIPad && horizontalSizeClass == .regular
    }

    /// 是否处于 iPad 紧凑分屏（1/3 屏或 Slide Over）
    public static func isIPadCompact(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isIPad && horizontalSizeClass == .compact
    }

    /// 自适应歌单/专辑网格列配置
    /// - iPhone / Compact: 保持 2 列
    /// - iPad Regular: 依据屏幕宽度自适应 3 ~ 6 列（卡片宽度 160 ~ 240pt）
    public static func adaptiveCardColumns(
        for horizontalSizeClass: UserInterfaceSizeClass?,
        minWidth: CGFloat = 160,
        maxWidth: CGFloat = 240,
        spacing: CGFloat = 16
    ) -> [GridItem] {
        if isIPadRegular(horizontalSizeClass) {
            return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: spacing)]
        } else {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
    }

    /// 依据容器实际像素宽度自适应卡片列数（用于复杂多级分屏如 1/3、1/2、2/3 屏）
    public static func adaptiveCardColumnsByWidth(_ width: CGFloat, spacing: CGFloat = 16) -> [GridItem] {
        if width < 520 {
            // 1/3 屏 / 紧凑窗口：双列
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        } else if width < 800 {
            // 1/2 半分屏 / 竖屏：3 列
            return Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        } else if width < 1120 {
            // 2/3 分屏 / 11" 横屏：4 列
            return Array(repeating: GridItem(.flexible(), spacing: spacing), count: 4)
        } else {
            // 12.9" / 13" 横屏大屏：5 列
            return Array(repeating: GridItem(.flexible(), spacing: spacing), count: 5)
        }
    }

    /// 自适应歌曲列表列配置（基于尺寸类与自适应宽度保护）
    /// - iPhone / Compact: 单列直排
    /// - iPad Regular: 采用自适应宽度（最小 280pt），容器空间不足时自动降级为 1 列，杜绝歌名被挤压消失
    public static func songListColumns(
        for horizontalSizeClass: UserInterfaceSizeClass?,
        spacing: CGFloat = 16
    ) -> [GridItem] {
        if isIPadRegular(horizontalSizeClass) {
            return [
                GridItem(.adaptive(minimum: 280, maximum: .infinity), spacing: spacing)
            ]
        } else {
            return [GridItem(.flexible())]
        }
    }

    /// 依据当前容器可用宽度动态分配歌曲网格列（对标 Apple Music iPad 官方流态）
    /// - 容器宽度 < 580pt: 保证 1 列全宽展开（大屏竖屏、1/2 半分屏等场景完美呈现完整歌名、歌手与操作）
    /// - 容器宽度 >= 580pt: 依据 280pt 最小跨度平滑呈现 2~3 列
    public static func songListColumns(
        forAvailableWidth width: CGFloat,
        minWidth: CGFloat = 280,
        spacing: CGFloat = 16
    ) -> [GridItem] {
        if width < 580 {
            return [GridItem(.flexible())]
        } else {
            return [GridItem(.adaptive(minimum: minWidth, maximum: .infinity), spacing: spacing)]
        }
    }

    /// iPad 宽屏下的内容区最大宽度约束（防止横屏内容被无意义拉伸过宽）
    public static func contentMaxWidth(for horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        if isIPadRegular(horizontalSizeClass) {
            return 1360
        } else {
            return 860
        }
    }

    /// 每页展示项数自适应（iPad 大屏下展示更多内容以铺满行）
    public static func recommendedItemCount(for horizontalSizeClass: UserInterfaceSizeClass?, compactCount: Int, regularCount: Int) -> Int {
        isIPadRegular(horizontalSizeClass) ? regularCount : compactCount
    }
}

/// 设备真实硬件与显示规格信息探测器（100% 动态读取内核与 UIKit 硬件指标）
public struct ATMusicDeviceInfo {
    /// 真实硬件型号标识符（如 iPhone16,1, iPad14,3, arm64 等）
    public static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    /// 真实设备营销名称（如 iPhone 15 Pro, iPhone 16 Pro Max, iPad Pro 11-inch M4 等）
    public static var marketingModelName: String {
        let identifier = hardwareIdentifier
        if let name = modelMapping[identifier] {
            return name
        }
        #if targetEnvironment(simulator)
        if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           let name = modelMapping[simModel] {
            return "\(name) (模拟器)"
        }
        return "iOS 模拟器 (\(identifier))"
        #else
        if identifier.hasPrefix("iPhone") {
            return "iPhone (\(identifier))"
        }
        if identifier.hasPrefix("iPad") {
            return "iPad (\(identifier))"
        }
        return "\(UIDevice.current.model) (\(identifier))"
        #endif
    }

    /// 真实显示分辨率、逻辑点数与屏幕缩放比率
    @MainActor
    public static var displayMetricsSummary: String {
        let bounds = ATMusicDisplayMetrics.bounds
        let scale = ATMusicDisplayMetrics.scale
        let pixelWidth = Int(round(bounds.width * scale))
        let pixelHeight = Int(round(bounds.height * scale))
        return "\(Int(bounds.width))×\(Int(bounds.height)) pt · @\(Int(round(scale)))x (\(pixelWidth)×\(pixelHeight) px)"
    }

    private static let modelMapping: [String: String] = [
        // iPhone 16 系列
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        // iPhone 15 系列
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        // iPhone 14 系列
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        // iPhone 13 系列
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,5": "iPhone 13",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,6": "iPhone SE (第 3 代)",
        // iPhone 12 系列
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone12,8": "iPhone SE (第 2 代)",
        // iPhone 11 系列
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        // iPhone X 系列
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone10,3": "iPhone X",
        "iPhone10,6": "iPhone X",
        // iPad Pro M4
        "iPad16,3": "iPad Pro 11-inch (M4)",
        "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)",
        "iPad16,6": "iPad Pro 13-inch (M4)",
        // iPad Pro M2
        "iPad14,3": "iPad Pro 11-inch (第 4 代)",
        "iPad14,4": "iPad Pro 11-inch (第 4 代)",
        "iPad14,5": "iPad Pro 12.9-inch (第 6 代)",
        "iPad14,6": "iPad Pro 12.9-inch (第 6 代)",
        // iPad Pro M1
        "iPad13,4": "iPad Pro 11-inch (第 3 代)",
        "iPad13,5": "iPad Pro 11-inch (第 3 代)",
        "iPad13,6": "iPad Pro 11-inch (第 3 代)",
        "iPad13,7": "iPad Pro 11-inch (第 3 代)",
        "iPad13,8": "iPad Pro 12.9-inch (第 5 代)",
        "iPad13,9": "iPad Pro 12.9-inch (第 5 代)",
        "iPad13,10": "iPad Pro 12.9-inch (第 5 代)",
        "iPad13,11": "iPad Pro 12.9-inch (第 5 代)",
        // iPad Air M2
        "iPad14,8": "iPad Air 11-inch (M2)",
        "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",
        // iPad Air M1 & 之前
        "iPad13,1": "iPad Air (第 4 代)",
        "iPad13,2": "iPad Air (第 4 代)",
        "iPad13,16": "iPad Air (第 5 代)",
        "iPad13,17": "iPad Air (第 5 代)",
        // iPad mini
        "iPad14,1": "iPad mini (第 6 代)",
        "iPad14,2": "iPad mini (第 6 代)",
        "iPad16,1": "iPad mini (A17 Pro)",
        "iPad16,2": "iPad mini (A17 Pro)",
        // iPad 数字代
        "iPad13,18": "iPad (第 10 代)",
        "iPad13,19": "iPad (第 10 代)",
        "iPad12,1": "iPad (第 9 代)",
        "iPad12,2": "iPad (第 9 代)",
    ]
}
