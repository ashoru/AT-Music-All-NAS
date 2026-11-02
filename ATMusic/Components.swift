import SwiftUI
import ImageIO
import CoreImage.CIFilterBuiltins

// MARK: - 工具

func atmusicSongCountText(_ count: Int) -> String {
    atmusicLocalized("\(count) 首", "\(count) songs")
}

func atmusicLocalSongCountText(_ count: Int) -> String {
    atmusicLocalized("\(count) 首 · 本机", "\(count) songs · On device")
}

func atmusicTimeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - 触感反馈（复用生成器实例，避免每次点击创建新对象造成额外开销/发热）

enum ATMusicHaptics {
    static let enabledKey = "atmusic.haptics.enabled"

    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func prepare() {
        guard isEnabled else { return }
        lightImpact.prepare()
        mediumImpact.prepare()
        selection.prepare()
    }

    static func tap() {
        guard isEnabled else { return }
        lightImpact.impactOccurred()
    }

    static func medium() {
        guard isEnabled else { return }
        mediumImpact.impactOccurred()
    }

    static func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    static func select() {
        guard isEnabled else { return }
        selection.selectionChanged()
    }
}

@MainActor
enum ATMusicDisplayMetrics {
    static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.screen
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var bounds: CGRect {
        screen?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
    }

    static var scale: CGFloat { screen?.scale ?? 1 }
}

// MARK: - 按压动效

struct GlassPressButtonStyle: ButtonStyle {
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    var scale: CGFloat = 0.94

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var pressedScale: CGFloat {
        switch uiStyle {
        case .liquid: return max(scale, 0.985)
        case .clear: return max(scale, 0.975)
        case .compact: return max(scale, 0.965)
        case .nativeClean: return max(scale, 0.980)
        }
    }

    private var pressedOpacity: Double {
        switch uiStyle {
        case .liquid: return 0.90
        case .clear: return 0.84
        case .compact: return 0.82
        case .nativeClean: return 0.78
        }
    }

    private var pressedBrightness: Double {
        switch uiStyle {
        case .liquid: return 0.015
        case .clear: return 0.010
        case .compact: return 0.006
        case .nativeClean: return 0.0
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        // 四套 UI 都必须有明确按压反馈。
        // Liquid 只做很轻的缩放/透明度变化，避免和系统 interactive glass 冲突；
        // 其余三套没有系统玻璃按压态，因此反馈更明显。
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .brightness(configuration.isPressed ? pressedBrightness : 0)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

// MARK: - 背景氛围（液态玻璃需要有可采样的动态内容）

struct GlassBackdrop: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.hideDynamicEffects") private var hideDynamicEffects = false
    /// 自定义背景色（nil 使用默认氛围渐变）
    var customColor: Color? = nil
    /// 主页模式：即使“同步到全部页面”关闭，也始终显示壁纸/背景色（仅发现页传 true）
    var homeMode: Bool = false
    /// 详情页使用原生氛围背景，不跟随全局壁纸同步
    var ignoreCustomBackground: Bool = false
    /// 主页壁纸额外模糊半径
    var wallpaperBlur: CGFloat = 0

    /// 当前页面是否启用自定义背景：同步开启时全部页面生效，关闭时仅主页生效
    private var showCustomBackground: Bool {
        !ignoreCustomBackground && (theme.backgroundSyncAll || homeMode)
    }

    /// 背景图上叠加的可读性遮罩：浅色模式几乎不压暗，深色模式适度压暗
    private var wallpaperOverlay: [Color] {
        colorScheme == .dark
            ? [.black.opacity(0.35), .black.opacity(0.55)]
            : [.black.opacity(0.08), .black.opacity(0.18)]
    }

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    var body: some View {
        let _ = theme.accent
        let activeBackgroundColor = theme.customBackground(for: colorScheme) ?? customColor
        let activeBackgroundImage = theme.customBackgroundImage(for: colorScheme)
        ZStack {
            if uiStyle == .nativeClean, !showCustomBackground || (activeBackgroundImage == nil && activeBackgroundColor == nil) {
                Color(UIColor.systemBackground)
            } else if let image = activeBackgroundImage, showCustomBackground {
                WallpaperImage(image: image, blurRadius: wallpaperBlur)
                LinearGradient(colors: wallpaperOverlay, startPoint: .top, endPoint: .bottom)
            } else if showCustomBackground, let activeBackgroundColor {
                LinearGradient(
                    colors: [activeBackgroundColor.opacity(0.9), activeBackgroundColor.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                LinearGradient.atmusicBackdrop
            }
            if uiStyle == .liquid && !hideDynamicEffects {
                // 这些光晕只负责给 iOS 27 玻璃提供背景层次。
                // 用径向渐变代替大半径实时高斯模糊：视觉保持柔和，但滚动时少两层高开销离屏合成。
                RadialGradient(
                    colors: [Color.atmusicAmber.opacity(0.16), Color.atmusicAmber.opacity(0.045), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 185
                )
                    .frame(width: 340, height: 340)
                    .offset(x: 150, y: -300)
                RadialGradient(
                    colors: [Color.atmusicSage.opacity(0.14), Color.atmusicSage.opacity(0.035), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 170
                )
                    .frame(width: 300, height: 300)
                    .offset(x: -160, y: 340)
            }
        }
        .ignoresSafeArea()
    }
}


// MARK: - 背景墙纸（上传图片：固定全屏布局，不影响其他 UI 尺寸；小图轻度柔化避免像素感）

struct WallpaperImage: View {
    let image: UIImage
    var blurRadius: CGFloat = 0

    /// 小于约 700x700 视为小图：放大时轻度模糊柔化，避免满屏马赛克
    private static func isSmall(_ image: UIImage) -> Bool {
        image.size.width * image.size.height < 480_000
    }

    var body: some View {
        // 用 GeometryReader 明确采用父容器尺寸渲染，图片尺寸/比例与 UI 布局完全隔离
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .blur(radius: max(Self.isSmall(image) ? 5 : 0, blurRadius))
        }
        .ignoresSafeArea()
    }
}

// MARK: - 全局容器（跟随全局 UI 样式）

struct ATMusicGlass<S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.hideLiquidGlass") private var hideLiquidGlass = false

    let shape: S
    var forceLiquid = false

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var isLiquid: Bool {
        // 全局 UI 样式是最高优先级：局部 forceLiquid 不能把其它三种样式强行改回液态。
        !hideLiquidGlass && uiStyle == .liquid
    }

    var body: some View {
        Group {
            if isLiquid {
                // 原生液态玻璃质感：在全系统版本（iOS 16+）均具备清透基底、液态渐变光晕与晶莹反光边缘
                if #available(iOS 26, *) {
                    GlassEffectContainer {
                        shape
                            .fill(.clear)
                            .glassEffect(.clear, in: shape)
                    }
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.16 : 0.28),
                                    Color.white.opacity(colorScheme == .dark ? 0.04 : 0.08),
                                    Color.atmusicAmber.opacity(colorScheme == .dark ? 0.08 : 0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    .overlay {
                        shape.stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.50 : 0.65),
                                    Color.white.opacity(colorScheme == .dark ? 0.15 : 0.25),
                                    Color.atmusicAmber.opacity(colorScheme == .dark ? 0.35 : 0.20)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                    }
                    .shadow(
                        color: Color.atmusicAmber.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        radius: 12,
                        y: 4
                    )
                }
            } else {
                switch uiStyle {
                case .clear:
                    // 磨砂玻璃风格
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            shape.stroke(
                                Color.white.opacity(colorScheme == .dark ? 0.14 : 0.22),
                                lineWidth: 0.7
                            )
                        }
                case .compact:
                    // 紧凑淡雅风格
                    shape
                        .fill(Color.atmusicGlassFill.opacity(0.78))
                        .overlay {
                            shape.stroke(
                                Color.atmusicComment.opacity(colorScheme == .dark ? 0.15 : 0.10),
                                lineWidth: 0.6
                            )
                        }
                case .nativeClean:
                    // Apple 简洁风格
                    shape
                        .fill(Color.atmusicGlassFill.opacity(0.62))
                        .overlay {
                            shape.stroke(
                                Color.primary.opacity(0.06),
                                lineWidth: 0.5
                            )
                        }
                case .liquid:
                    shape.fill(.ultraThinMaterial)
                }
            }
        }
    }
}

/// 统一表面容器：自动跟随四个全局 UI 样式保持统一质感
struct ATMusicSurface<S: Shape>: View {
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    let shape: S

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    var body: some View {
        ATMusicGlass(shape: shape)
    }
}

// MARK: - 参考版设置页表面

/// 设置页统一紧凑表面。材质由 `ATMusicGlass` 跟随四种全局 UI 样式，
/// 设置页、播放器设置和后续新增设置只共享圆角/描边，不再局部强制某一种材质。
struct SettingsCompactGlassSurface: View {
    let cornerRadius: CGFloat
    var emphasized = false

    init(cornerRadius: CGFloat = 18, emphasized: Bool = false) {
        self.cornerRadius = cornerRadius
        self.emphasized = emphasized
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ATMusicGlass(shape: shape)
            .overlay {
                shape.stroke(
                    emphasized ? Color.atmusicAmber.opacity(0.34) : Color.primary.opacity(0.10),
                    lineWidth: emphasized ? 1 : 0.7
                )
            }
    }
}

/// 参考版设置页的“目录分组”：标题、说明和紧凑内容保持在同一张玻璃面板内。
/// 内容闭包不绑定具体业务，因此后续增加新音源或 iCloud 设置时可以直接复用。
struct SettingsCatalogGroup<Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 28, height: 28)
                    .background(Color.atmusicAmber.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    if let subtitle, !subtitle.isEmpty {
                        Text(LocalizedStringKey(subtitle))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    SettingsCompactGlassSurface(cornerRadius: 16)
                }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            SettingsCompactGlassSurface(cornerRadius: 22)
        }
    }
}

/// 设置页使用的大尺寸液态弹层。
/// 规范支持大屏 FormSheet 与 iPhone 大弹层，彻底移除 medium 交互背景穿透，防止 iPadOS 抛出 largestUndimmedDetentIdentifier 异常闪退。
struct SettingsLiquidSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

// MARK: - 通用卡片（跟随全局 UI 样式）

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 24
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @ViewBuilder var content: () -> Content

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var resolvedCornerRadius: CGFloat {
        if uiStyle == .compact { return min(cornerRadius, 16) }
        if uiStyle == .nativeClean { return min(cornerRadius, 18) }
        return cornerRadius
    }

    private var resolvedPadding: CGFloat {
        if uiStyle == .compact { return 12 }
        if uiStyle == .nativeClean { return 13 }
        return 16
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
        content()
            .padding(resolvedPadding)
            .background { ATMusicGlass(shape: shape) }
            .clipShape(shape)
            .atmusicCardShadow(radius: uiStyle == .nativeClean ? 3 : 9, y: uiStyle == .nativeClean ? 1 : 3)
    }
}

/// 播放/暂停图标切换过渡：iOS 17+ 使用符号替换动画，低版本回退透明度过渡
struct ATMusicContentFade: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 17.0, *) {
                content.contentTransition(.opacity)
            } else {
                content
            }
        }
    }
}

struct ATMusicSymbolReplace: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 17.0, *) {
                content.contentTransition(.symbolEffect(.replace))
            } else {
                content
            }
        }
    }
}

/// 玻璃过渡容器：iOS 26+ 才支持 `glassEffectTransition`，低版本不施加。
struct ATMusicGlassTransition: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffectTransition(.materialize)
            } else {
                content
            }
        }
    }
}

/// 播放中的 waveform 呼吸动画：iOS 17+ 使用符号特效，低版本静态显示。
struct ATMusicWaveformEffect: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 17.0, *) {
                content.symbolEffect(.variableColor.iterative.reversing)
            } else {
                content
            }
        }
    }
}

/// 播放/暂停 morph 图标：三角播放态与双竖线暂停态共享一个固定画布，避免按钮尺寸跳动。
struct PlayPauseMorphIcon: View {
    let isPlaying: Bool
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            .frame(width: size + 6, height: size + 6)
            .modifier(ATMusicSymbolReplace())
    }
}


/// iOS 27 风格的原生 Liquid Glass matched-geometry 过渡。
private struct ATMusicMatchedGlassModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *), let namespace {
            content
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content
        }
    }
}

struct ATMusicGlassMorphContainer<Content: View>: View {
    var spacing: CGFloat? = 12
    @ViewBuilder let content: () -> Content

    @ViewBuilder
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension View {
    func atmusicMatchedGlass(_ id: String, in namespace: Namespace.ID?) -> some View {
        modifier(ATMusicMatchedGlassModifier(id: id, namespace: namespace))
    }
}

// MARK: - iOS 15 兼容包装（低版本自动降级）

/// iOS 16+ 使用 NavigationStack，iOS 15 回退 NavigationView（堆栈样式）
struct ATMusicNavigationStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }.navigationViewStyle(.stack)
        }
    }
}

/// 带可编程路径的导航堆栈，用于从卡片点击进入统一的详情页。
struct ATMusicNavigationStackWithPath<Route: Hashable, Content: View>: View {
    @Binding var path: [Route]
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack(path: $path) { content() }
        } else {
            NavigationView { content() }.navigationViewStyle(.stack)
        }
    }
}

extension View {
    /// iOS 16+ 的类型化导航目的地，低版本保持原有页面结构。
    @ViewBuilder
    func atmusicNavigationDestination<Route: Hashable, Destination: View>(
        for route: Route.Type,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) -> some View {
        if #available(iOS 16, *) {
            navigationDestination(for: route, destination: destination)
        } else {
            self
        }
    }
}

/// 弹窗尺寸（自定义枚举，避免在低版本引用 iOS 16 类型）
enum ATMusicDetent {
    case medium
    case large
    case fraction(CGFloat)
    case height(CGFloat)
}

/// 弹窗尺寸与拖拽指示条：iOS 16+ 生效，低版本全屏展示
struct ATMusicSheetModifier: ViewModifier {
    let detents: [ATMusicDetent]
    var dragIndicator: Bool?

    @available(iOS 16, *)
    private static func makeDetents(_ detents: [ATMusicDetent]) -> Set<PresentationDetent> {
        var result: Set<PresentationDetent> = []
        for detent in detents {
            switch detent {
            case .medium: result.insert(.medium)
            case .large: result.insert(.large)
            case .fraction(let f): result.insert(.fraction(f))
            case .height(let h): result.insert(.height(h))
            }
        }
        return result
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            if let dragIndicator {
                content
                    .presentationDetents(Self.makeDetents(detents))
                    .presentationDragIndicator(dragIndicator ? .visible : .hidden)
            } else {
                content
                    .presentationDetents(Self.makeDetents(detents))
            }
        } else {
            content
        }
    }
}

extension View {
    /// iOS 16+ 隐藏滚动条，低版本保持默认
    @ViewBuilder
    func atmusicScrollIndicatorsHidden() -> some View {
        if #available(iOS 16, *) { self.scrollIndicators(.hidden) } else { self }
    }

    /// iOS 16+ 滚动时收起键盘，低版本保持默认
    @ViewBuilder
    func atmusicScrollDismissesKeyboard() -> some View {
        if #available(iOS 16, *) { self.scrollDismissesKeyboard(.interactively) } else { self }
    }

    /// iOS 16+ 隐藏滚动内容默认背景，低版本保持默认
    @ViewBuilder
    func atmusicScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16, *) { self.scrollContentBackground(.hidden) } else { self }
    }

    /// 在歌单、排行榜等详情页底部保留可用的迷你播放器。
    func atmusicDetailMiniPlayer() -> some View {
        modifier(ATMusicDetailMiniPlayerModifier())
    }
}

private struct ATMusicDetailMiniPlayerModifier: ViewModifier {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var showPlayer = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.currentSong != nil {
                    ATMusicGlassMorphContainer(spacing: 10) {
                        MiniPlayerView(
                            showPlayer: $showPlayer,
                            presentation: .dock
                        )
                        .environmentObject(player.clock)
                        .environmentObject(theme)
                            .environmentObject(favorites)
                            .modifier(ATMusicGlassTransition())
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            .fullScreenCover(isPresented: $showPlayer) {
                // 详情页使用与主页相同的播放页容器，确保顶部下拉手势可以关闭播放器。
                ATMusicNowPlayingPresentation {
                    PlayerView(isPresented: $showPlayer)
                        .environmentObject(auth)
                        .environmentObject(player)
                        .environmentObject(player.clock)
                        .environmentObject(theme)
                        .environmentObject(favorites)
                }
            }
    }
}

// MARK: - 封面图

// MARK: - 图像轻量硬件靶向下采样引擎（WWDC 推荐最佳实践，彻底杜绝大图全量解码显存爆炸）

enum ImageDownsampler {
    static func downsample(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            return nil
        }
        return downsample(imageSource: imageSource, maxPixelSize: maxPixelSize)
    }

    static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
            return nil
        }
        return downsample(imageSource: imageSource, maxPixelSize: maxPixelSize)
    }

    private static func downsample(imageSource: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: downsampledImage)
    }
}

enum ATMusicRemoteCoverCache {
    private static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024 // 80 MB 显存硬顶，彻底杜绝 OOM 闪退
        cache.countLimit = 200
        return cache
    }()

    static func image(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return images.object(forKey: url as NSURL)
    }

    static func store(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? (Int(image.size.width * image.size.height) * 4)
        images.setObject(image, forKey: url as NSURL, cost: cost)
    }

    static func remove(for url: URL?) {
        guard let url else { return }
        images.removeObject(forKey: url as NSURL)
    }

    static func removeAll() {
        images.removeAllObjects()
    }
}

extension URL {
    var coverIdentity: String {
        let resolved = ManagedAudioPath.resolveFileURL(self) ?? self
        if resolved.isFileURL {
            return resolved.standardizedFileURL.path
        }
        guard var comp = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return resolved.absoluteString
        }
        let ephemeralKeys: Set<String> = ["_atmusic_refresh", "_atmusic_verify", "_sid", "_", "t"]
        comp.queryItems = comp.queryItems?.filter { !ephemeralKeys.contains($0.name) }
        return comp.string ?? resolved.absoluteString
    }
}

@MainActor
final class ATMusicCoverImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var loadedURL: URL?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadFailed: Bool = false

    private var currentTargetURL: URL?
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?

    func load(_ url: URL?, targetPixelSize: CGFloat = 800, isRetry: Bool = false, force: Bool = false) async {
        if !isRetry {
            retryCount = 0
            retryTask?.cancel()
            retryTask = nil
        }
        currentTargetURL = url
        guard let url else {
            image = nil
            loadedURL = nil
            isLoading = false
            loadFailed = false
            return
        }
        let resolvedURL = ManagedAudioPath.resolveFileURL(url) ?? url
        if force {
            ATMusicRemoteCoverCache.remove(for: resolvedURL)
            ATMusicRemoteCoverCache.remove(for: url)
            if resolvedURL.isFileURL {
                ATMusicImageFileCache.remove(resolvedURL.path)
            }
            URLCache.shared.removeCachedResponse(for: URLRequest(url: resolvedURL))
            URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
            image = nil
            loadedURL = nil
        } else {
            if loadedURL == resolvedURL, image != nil {
                isLoading = false
                loadFailed = false
                return
            }
            if let cached = ATMusicRemoteCoverCache.image(for: resolvedURL) {
                loadedURL = resolvedURL
                image = cached
                isLoading = false
                loadFailed = false
                return
            }
            if let cached = ATMusicRemoteCoverCache.image(for: url) {
                loadedURL = resolvedURL
                image = cached
                isLoading = false
                loadFailed = false
                return
            }
        }

        isLoading = true
        loadFailed = false

        if resolvedURL.isFileURL {
            let decoded: UIImage? = await Task.detached(priority: .utility) {
                if !force, let cached = ATMusicImageFileCache.image(at: resolvedURL.path) {
                    return cached
                }
                if let downsampled = ImageDownsampler.downsample(at: resolvedURL, maxPixelSize: targetPixelSize) {
                    return downsampled
                }
                guard let img = UIImage(contentsOfFile: resolvedURL.path)?.preparingForDisplay() else {
                    return nil
                }
                return img
            }.value
            guard !Task.isCancelled, currentTargetURL == url else {
                isLoading = false
                return
            }
            if let decoded {
                loadedURL = resolvedURL
                ATMusicRemoteCoverCache.store(decoded, for: resolvedURL)
                image = decoded
                isLoading = false
                loadFailed = false
                return
            } else {
                loadedURL = nil
                image = nil
                isLoading = false
                loadFailed = true
                scheduleAutoRetryIfNeeded(for: url)
                return
            }
        }

        do {
            var request = URLRequest(url: resolvedURL)
            request.timeoutInterval = 15
            request.cachePolicy = (isRetry || force) ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, currentTargetURL == url else {
                isLoading = false
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                loadedURL = nil
                image = nil
                isLoading = false
                loadFailed = true
                scheduleAutoRetryIfNeeded(for: url)
                return
            }
            let decoded: UIImage? = await Task.detached(priority: .utility) {
                if let downsampled = ImageDownsampler.downsample(data: data, maxPixelSize: targetPixelSize) {
                    return downsampled
                }
                return UIImage(data: data)?.preparingForDisplay()
            }.value
            guard !Task.isCancelled, currentTargetURL == url, let decoded else {
                loadedURL = nil
                image = nil
                isLoading = false
                loadFailed = true
                scheduleAutoRetryIfNeeded(for: url)
                return
            }
            loadedURL = resolvedURL
            ATMusicRemoteCoverCache.store(decoded, for: resolvedURL)
            image = decoded
            isLoading = false
            loadFailed = false
        } catch {
            guard !Task.isCancelled, currentTargetURL == url else {
                isLoading = false
                return
            }
            loadedURL = nil
            image = nil
            isLoading = false
            loadFailed = true
            scheduleAutoRetryIfNeeded(for: url)
        }
    }

    private func scheduleAutoRetryIfNeeded(for url: URL) {
        guard retryCount < 5 else { return }
        retryCount += 1
        let delays = [1.0, 2.0, 3.0, 5.0, 8.0]
        let delaySeconds = delays[min(retryCount - 1, delays.count - 1)]
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.load(url, isRetry: true)
        }
    }

    func retry() async {
        guard let url = currentTargetURL else { return }
        retryCount = 0
        retryTask?.cancel()
        retryTask = nil
        await load(url, isRetry: true, force: true)
    }
}

struct CoverImage: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 12
    /// 封面未加载时的提示文字（播放器大封面用：等待开始播放）；nil 显示中性图标
    var emptyHint: String? = nil
    /// 独立宽高覆盖（默认 nil 用 size 正方形；宽版 2:1 卡片传 width/height）
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var isFlexible: Bool = false
    @StateObject private var loader = ATMusicCoverImageLoader()

    private var targetPixelSize: CGFloat {
        let maxSide = max(width ?? 0, height ?? 0, size)
        if maxSide <= 0 { return 750 }
        if maxSide <= 64 { return 180 }
        if maxSide <= 140 { return 420 }
        return 800
    }

    private var displayedImage: UIImage? {
        let resolved = ManagedAudioPath.resolveFileURL(url) ?? url
        if let cached = ATMusicRemoteCoverCache.image(for: resolved) { return cached }
        if let url, let cached = ATMusicRemoteCoverCache.image(for: url) { return cached }
        if (loader.loadedURL == resolved || loader.loadedURL == url), let image = loader.image { return image }
        return nil
    }

    // 布局尺寸完全由外层固定容器决定；AsyncImage 只放在 overlay 中渲染，
    // 图片加载完成与否都不会改变任何布局尺寸（根治"封面加载后错乱"）。
    var body: some View {
        Group {
            if isFlexible {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            let side = min(geo.size.width, geo.size.height)
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.atmusicGlassFill)
                                .overlay {
                                    if let displayedImage {
                                        Image(uiImage: displayedImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: side, height: side)
                                            .clipped()
                                    } else {
                                        placeholderIcon
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                                .frame(width: side, height: side)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                let w = width ?? size
                let h = height ?? size
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.atmusicGlassFill)
                    .frame(width: w, height: h)
                    .overlay {
                        if let displayedImage {
                            Image(uiImage: displayedImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: w, height: h)
                                .clipped()
                        } else {
                            placeholderIcon
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .task(id: url) {
            let resolved = ManagedAudioPath.resolveFileURL(url) ?? url
            if ATMusicRemoteCoverCache.image(for: resolved) == nil {
                await loader.load(resolved, targetPixelSize: targetPixelSize)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicCoverDidUpdate)) { note in
            let resolved = ManagedAudioPath.resolveFileURL(url) ?? url
            guard let resolved else { return }
            if let updatedURL = note.object as? URL {
                let resolvedUpdated = ManagedAudioPath.resolveFileURL(updatedURL) ?? updatedURL
                if updatedURL == resolved || updatedURL == url ||
                   resolvedUpdated == resolved || (url != nil && resolvedUpdated == url!) ||
                   updatedURL.coverIdentity == resolved.coverIdentity ||
                   (url != nil && updatedURL.coverIdentity == url!.coverIdentity) {
                    Task { await loader.load(resolved, targetPixelSize: targetPixelSize, isRetry: false, force: true) }
                }
            } else {
                Task { await loader.load(resolved, targetPixelSize: targetPixelSize, isRetry: false, force: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if displayedImage == nil && loader.loadFailed {
                Task { await loader.retry() }
            }
        }
    }

    private var placeholderIcon: some View {
        let displayDim = size > 0 ? size : 80
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.atmusicGlassFill)
            if let emptyHint {
                Text(emptyHint)
                    .font(ATMusicFont.appFont(max(11, min(displayDim * 0.09, 15)), .medium))
                    .foregroundStyle(Color.atmusicComment)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            } else if loader.loadFailed {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: max(14, displayDim * 0.24), weight: .medium))
                        .foregroundStyle(Color.atmusicComment)
                    if displayDim >= 100 {
                        Text("点击重试")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment.opacity(0.85))
                    }
                }
            } else {
                // 中性等待图标（不再使用音乐音符）
                Image(systemName: "waveform")
                    .font(.system(size: max(14, displayDim * 0.28), weight: .medium))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if displayedImage == nil || loader.loadFailed {
                Task { await loader.retry() }
            }
        }
    }
}

// MARK: - 音源标识

extension SongSource {
    var displayName: String { atmusicDisplayName }

    var atmusicDisplayName: String {
        switch self {
        case .netease: return "网易云"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗"
        case .local: return "本地"
        case .synology: return "NAS"
        case .subsonic: return "Subsonic"
        case .jellyfin: return "Jellyfin"
        case .webdav: return "WebDAV"
        }
    }

    var atmusicBadgeColor: Color {
        switch self {
        case .netease: return Color(red: 0.88, green: 0.16, blue: 0.16)
        case .qq: return Color(red: 0.08, green: 0.62, blue: 0.35)
        case .kugou: return Color(red: 0.10, green: 0.42, blue: 0.82)
        case .local: return Color(red: 0.55, green: 0.34, blue: 0.78)
        case .synology: return Color(red: 0.12, green: 0.34, blue: 0.72)
        case .subsonic: return Color(red: 0.26, green: 0.62, blue: 0.28)
        case .jellyfin: return Color(red: 0.65, green: 0.33, blue: 0.86)
        case .webdav: return Color(red: 0.55, green: 0.55, blue: 0.58)
        }
    }
}

struct SourceBadgeView: View {
    let source: SongSource
    var compact = false

    var body: some View {
        Text(source.atmusicDisplayName)
            .font(ATMusicFont.appFont(compact ? 8 : 9, .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, compact ? 4 : 5)
            .frame(height: compact ? 14 : 18)
            .background(Capsule().fill(source.atmusicBadgeColor.opacity(0.92)))
            .fixedSize(horizontal: true, vertical: false)
    }
}


// MARK: - 超长文本横向滚动（跑马灯）

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 歌名跑马灯（Apple Music 式）：放得下时静止；放不下时渲染两份相同文本，
/// 以恒定速度单向无缝循环滚动——第二份与第一份完全一致，绕回瞬间画面无跳变、无回弹。
/// 切歌/尺寸变化后先停留 startDelay 再起滚；isPaused 时回到开头静止（如正在拖动进度条）。
/// 滚动动画只由 scrolling 开关驱动（repeatForever），父视图刷新不会重启，避免卡顿。
struct MarqueeText: View {
    let text: String
    let font: Font
    var color: Color = .white
    var height: CGFloat = 26
    var isPaused: Bool = false
    /// 滚动速度（pt/s）：越慢越不抢眼，与歌词同屏时宜更慢。
    var speed: CGFloat = 34
    /// 每次（重新）起滚前的停留秒数，先让开头可读。
    var startDelay: Double = 1.6

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var scrolling = false

    private let copyGap: CGFloat = 56

    private var needsScroll: Bool {
        containerWidth > 0 && textWidth > containerWidth + 1
    }

    private var loopDistance: CGFloat { textWidth + copyGap }
    private var loopDuration: Double { Double(loopDistance / max(speed, 1)) }
    private var eligibilityKey: String { "\(text)#\(needsScroll)#\(isPaused)" }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                HStack(spacing: copyGap) {
                    label
                    if needsScroll {
                        label
                    }
                }
                .offset(x: scrolling ? -loopDistance : 0)
                .animation(
                    scrolling
                        ? .linear(duration: loopDuration).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.25),
                    value: scrolling
                )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .mask {
                if needsScroll {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.86),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Rectangle().fill(.white)
                }
            }
            .onAppear {
                if abs(containerWidth - geo.size.width) > 0.5 { containerWidth = geo.size.width }
            }
            .onChange(of: geo.size.width) { newWidth in
                if abs(containerWidth - newWidth) > 0.5 { containerWidth = newWidth }
            }
        }
        .frame(height: height)
        .onPreferenceChange(MarqueeTextWidthKey.self) { newWidth in
            if abs(textWidth - newWidth) > 0.5 { textWidth = newWidth }
        }
        .task(id: eligibilityKey) {
            scrolling = false
            guard needsScroll, !isPaused else { return }
            try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            if Task.isCancelled { return }
            scrolling = true
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { textGeo in
                    Color.clear.preference(key: MarqueeTextWidthKey.self, value: textGeo.size.width)
                }
            )
    }
}

// MARK: - 会员标识小标（SVIP 金色 / VIP 红色）

struct VIPBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ATMusicFont.appFont(9, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(text == "SVIP" ? Color(red: 0.85, green: 0.62, blue: 0.18) : Color(red: 0.93, green: 0.25, blue: 0.22)))
    }
}

/// 歌曲列表/播放器使用的紧凑会员标识：避免把标题挤成两行，和音源徽标保持同高。
struct SongVIPBadgeView: View {
    var compact = true

    var body: some View {
        Text("V")
            .font(ATMusicFont.appFont(compact ? 8 : 10, .bold))
            .foregroundStyle(.white)
            // 与来源平台标签固定同高，歌曲列表右侧能保持一条干净的水平基线。
            .frame(width: compact ? 14 : 18, height: compact ? 14 : 18)
            .background(Circle().fill(Color(red: 0.93, green: 0.25, blue: 0.22)))
            .accessibilityLabel("VIP")
    }
}

// MARK: - 全局液态选中气泡 / 选中表面

/// 全局统一的“选中态”表面。
/// - 默认液态：iOS 26+ 直接使用系统 `Glass.regular.tint(...).interactive()`，和系统 segmented 选中态使用同一套 Liquid Glass 能力。
/// - 其他三种全局 UI：自动回退到对应 ATMusicGlass 材质，只保留轻微选中强调，不强行套液态。
/// 所有底栏、分段选择、播放模式、播放器样式选择等选中态都应复用这里。
struct ATMusicLiquidSelectionSurface<S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.hideLiquidGlass") private var hideLiquidGlass = false

    let shape: S
    var accent: Color = .atmusicAmber
    var showsAccentGlow = true

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var isLiquid: Bool {
        !hideLiquidGlass && uiStyle == .liquid
    }

    var body: some View {
        Group {
            if isLiquid {
                if #available(iOS 26, *) {
                    shape
                        .fill(.clear)
                        .glassEffect(
                            .regular
                                .tint(accent.opacity(colorScheme == .dark ? 0.16 : 0.11))
                                .interactive(),
                            in: shape
                        )
                        .overlay {
                            shape.stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.42 : 0.62),
                                        Color.white.opacity(0.08),
                                        accent.opacity(showsAccentGlow ? 0.24 : 0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                        }
                } else {
                    legacyLiquidSurface
                }
            } else {
                ZStack {
                    ATMusicGlass(shape: shape)
                    shape.fill(nonLiquidSelectionTint)
                }
                .overlay {
                    shape.stroke(nonLiquidSelectionStroke, lineWidth: 0.7)
                }
            }
        }
        .shadow(
            color: isLiquid && showsAccentGlow ? accent.opacity(colorScheme == .dark ? 0.13 : 0.07) : .clear,
            radius: isLiquid ? 12 : 0,
            y: isLiquid ? 5 : 0
        )
    }

    private var legacyLiquidSurface: some View {
        ZStack {
            ATMusicGlass(shape: shape)
            shape.fill(accent.opacity(colorScheme == .dark ? 0.055 : 0.035))
        }
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.46 : 0.68),
                        Color.white.opacity(0.08),
                        accent.opacity(showsAccentGlow ? 0.32 : 0.12),
                        Color.white.opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }

    private var nonLiquidSelectionTint: Color {
        switch uiStyle {
        case .liquid: return accent.opacity(0.10)
        case .clear: return Color.white.opacity(colorScheme == .dark ? 0.08 : 0.14)
        case .compact: return accent.opacity(colorScheme == .dark ? 0.11 : 0.08)
        case .nativeClean: return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055)
        }
    }

    private var nonLiquidSelectionStroke: Color {
        switch uiStyle {
        case .liquid: return accent.opacity(0.28)
        case .clear: return Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
        case .compact: return Color.atmusicComment.opacity(0.18)
        case .nativeClean: return Color.primary.opacity(0.08)
        }
    }
}


/// 统一可选择表面：所有“选择器 / 筛选器 / 模式切换 / 平台切换”都应优先复用。
/// 四套 UI 不再强行共用同一种外观，而是保持“同一语义，不同主题表现”：
/// - 默认液态：系统 Liquid Glass + 主题色轻染；
/// - 磨砂玻璃：磨砂层 + 轻主题描边；
/// - 紧凑淡雅：低对比主题色浅底；
/// - Apple 简洁：系统主色/填充的极简选中态。
struct ATMusicSelectableSurface<S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    let selected: Bool
    let shape: S
    var accent: Color = .atmusicAmber

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    @ViewBuilder
    var body: some View {
        if selected {
            switch uiStyle {
            case .liquid:
                ATMusicLiquidSelectionSurface(shape: shape, accent: accent)

            case .clear:
                ZStack {
                    ATMusicSurface(shape: shape)
                    shape.fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.12))
                }
                .overlay {
                    shape.stroke(accent.opacity(colorScheme == .dark ? 0.30 : 0.22), lineWidth: 0.8)
                }

            case .compact:
                shape
                    .fill(accent.opacity(colorScheme == .dark ? 0.14 : 0.09))
                    .overlay {
                        shape.stroke(accent.opacity(colorScheme == .dark ? 0.30 : 0.22), lineWidth: 0.7)
                    }

            case .nativeClean:
                shape
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.060))
                    .overlay {
                        shape.stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.6)
                    }
            }
        } else {
            ATMusicSurface(shape: shape)
        }
    }
}

/// 选中项文字/图标颜色也跟随四套 UI，而不是统一硬编码白色或主题色。
private struct ATMusicSelectionForegroundModifier: ViewModifier {
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let selected: Bool
    let accent: Color
    let unselected: Color

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var selectedColor: Color {
        switch uiStyle {
        case .liquid:
            return accent
        case .clear:
            return Color.atmusicLabel
        case .compact:
            return accent
        case .nativeClean:
            return Color.primary
        }
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(selected ? selectedColor : unselected)
    }
}

extension View {
    func atmusicSelectionForeground(
        selected: Bool,
        accent: Color = .atmusicAmber,
        unselected: Color = .atmusicComment
    ) -> some View {
        modifier(
            ATMusicSelectionForegroundModifier(
                selected: selected,
                accent: accent,
                unselected: unselected
            )
        )
    }
}

/// 底栏使用的圆形液态选中气泡。内部直接复用全局选中表面，只额外保留顶部高光。
struct ATMusicLiquidSelectionBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    var accent: Color = .atmusicAmber
    var showsAccentGlow = true

    var body: some View {
        ATMusicLiquidSelectionSurface(
            shape: Circle(),
            accent: accent,
            showsAccentGlow: showsAccentGlow
        )
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28))
                .frame(width: 42, height: 2.5)
                .blur(radius: 0.5)
                .padding(.top, 13)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 8, y: 4)
    }
}

// MARK: - 玻璃图标按钮（清透 + 按压动效）

struct GlassIconButton: View {
    @EnvironmentObject private var theme: ThemeStore
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let systemName: String
    var size: CGFloat = 44
    var active = false
    var forceLiquid = false
    let action: () -> Void

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    var body: some View {
        let _ = theme.accent
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * (isNativeClean ? 0.42 : 0.38), weight: .semibold))
                .atmusicSelectionForeground(selected: active, accent: .atmusicAmber, unselected: isNativeClean ? Color.primary : Color.atmusicLabel)
                .frame(width: size, height: size)
                .background {
                    if active {
                        ATMusicSelectableSurface(selected: true, shape: Circle(), accent: .atmusicAmber)
                    } else {
                        ATMusicGlass(shape: Circle(), forceLiquid: forceLiquid)
                    }
                }
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

// MARK: - 玻璃按钮（清透 + 按压动效）

struct GlassButton: View {
    @EnvironmentObject private var theme: ThemeStore
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let title: String
    var systemName: String?
    var prominent = false
    let action: () -> Void

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    var body: some View {
        let _ = theme.accent
        Button {
            if prominent {
                ATMusicHaptics.medium()
            } else {
                ATMusicHaptics.tap()
            }
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemName {
                    Image(systemName: systemName)
                }
                Text(LocalizedStringKey(title))
            }
            .font(ATMusicFont.appFont(15, .semibold))
            .atmusicSelectionForeground(
                selected: prominent,
                accent: .atmusicAmber,
                unselected: Color.atmusicLabel
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                if prominent {
                    ATMusicSelectableSurface(selected: true, shape: Capsule(), accent: .atmusicAmber)
                } else {
                    ATMusicGlass(shape: Capsule())
                }
            }
            .overlay {
                if isNativeClean && !prominent {
                    Capsule().strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.7)
                }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

// MARK: - 区块标题

struct SectionHeader: View {
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let title: String
    var trailing: String?
    var titleColor: Color = Color.atmusicLabel
    var trailingColor: Color = Color.atmusicComment
    var onTrailingTap: (() -> Void)?

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(ATMusicFont.appFont(isNativeClean ? 26 : 21, .bold))
                .foregroundStyle(titleColor)
            Spacer()
            if let trailing {
                Button {
                    onTrailingTap?()
                } label: {
                    HStack(spacing: 3) {
                        Text(LocalizedStringKey(trailing))
                            .font(ATMusicFont.appFont(13, .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(trailingColor)
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.9))
            }
        }
    }
}

// MARK: - 空态 / 错误 / 加载

struct EmptyStateView: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.atmusicComment)
            Text(LocalizedStringKey(text))
                .font(ATMusicFont.appFont(14))
                .foregroundStyle(Color.atmusicComment)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.atmusicComment)
            Text(message)
                .font(ATMusicFont.appFont(14))
                .foregroundStyle(Color.atmusicComment)
                .multilineTextAlignment(.center)
            GlassButton(title: "重试", systemName: "arrow.clockwise", action: retry)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct LoadingStateView: View {
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let _ = theme.accent
        ProgressView()
            .controlSize(.large)
            .tint(Color.atmusicAmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

// MARK: - 二维码

struct QRCodeView: View {
    let text: String
    var size: CGFloat = 220

    var body: some View {
        if let image = Self.generateQR(from: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            EmptyView()
        }
    }

    private static func generateQR(from text: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - 当前播放指示（均衡器动效）

struct NowPlayingIndicator: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage("atmusic.hideDynamicEffects") private var lowPowerVisualMode = false

    @ViewBuilder
    var body: some View {
        let _ = theme.accent
        if #available(iOS 17.0, *) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: !accessibilityReduceMotion && !lowPowerVisualMode
                )
                .frame(width: 18, height: 16)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 18, height: 16)
        }
    }
}

// MARK: - 播放进度线（迷你播放器用）

struct ProgressLine: View {
    @EnvironmentObject private var theme: ThemeStore
    let progress: Double
    let duration: Double

    private var ratio: Double {
        guard duration > 0.001 else { return 0 }
        return min(max(progress / duration, 0), 1)
    }

    var body: some View {
        let _ = theme.accent
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.atmusicComment.opacity(0.25))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.atmusicAmber, Color.atmusicAmber.opacity(0.5)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geo.size.width * ratio, 6))
                    .shadow(color: Color.atmusicAmber.opacity(0.5), radius: 3, y: 1)
                    .overlay(alignment: .trailing) {
                        ZStack {
                            // 柔圆光晕（替代生硬方边阴影）
                            Circle()
                                .fill(Color.atmusicAmber.opacity(0.45))
                                .blur(radius: 4)
                                .frame(width: 14, height: 14)
                            Circle()
                                .fill(Color.atmusicAmber)
                                .frame(width: 5, height: 5)
                                .shadow(color: Color.atmusicAmber.opacity(0.8), radius: 2)
                        }
                    }
            }
        }
    }
}
// MARK: - 板块进入动画（首页错落渐入，纯视觉不影响布局）

struct SectionEntrance: ViewModifier {
    var delay: Double = 0

    func body(content: Content) -> some View {
        content
    }
}

extension View {
    /// 页面内板块错落渐入：opacity + 轻微上移，不影响布局
    func sectionEntrance(delay: Double = 0) -> some View {
        modifier(SectionEntrance(delay: delay))
    }
}

// MARK: - 全局轻提示（Toast，收藏/歌单等操作反馈用）

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var message: String?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, duration: Double = 2.2) {
        dismissTask?.cancel()
        message = text
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

struct ToastView: View {
    @ObservedObject var center: ToastCenter
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let _ = theme.accent
        Group {
            if let message = center.message {
                Text(message)
                    .font(ATMusicFont.appFont(14, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background { ATMusicGlass(shape: Capsule()) }
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 92)
        .animation(.default, value: center.message)
        .allowsHitTesting(false)
    }
}


// MARK: - 滑动多选 / 连续拖拽批量选择支持 (Swipe Multi-Select)

public struct MultiSelectRowFramePreference: PreferenceKey {
    public static var defaultValue: [Int: CGRect] = [:]
    public static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {}
}

public struct MultiSelectRowFrameModifier: ViewModifier {
    let index: Int
    let coordinateSpace: String

    public func body(content: Content) -> some View {
        content
    }
}

extension View {
    public func multiSelectRow(index: Int, coordinateSpace: String = "") -> some View {
        modifier(MultiSelectRowFrameModifier(index: index, coordinateSpace: coordinateSpace))
    }
}

/// 支持点按切换与零延迟连续滑动多选的复选圈（完全对标 iOS 原生滑动多选体验，零布局开销）
public struct MultiSelectCheckmark: View {
    let isSelected: Bool
    let index: Int
    var rowHeight: CGFloat = 64
    var coordinateSpace: String = ""
    let onToggle: () -> Void
    let onDragChange: (_ startIndex: Int, _ deltaRows: Int) -> Void
    let onDragEnd: () -> Void

    @State private var lastDelta: Int? = nil

    public init(
        isSelected: Bool,
        index: Int,
        rowHeight: CGFloat = 64,
        coordinateSpace: String = "",
        onToggle: @escaping () -> Void,
        onDragChange: @escaping (_ startIndex: Int, _ deltaRows: Int) -> Void,
        onDragEnd: @escaping () -> Void
    ) {
        self.isSelected = isSelected
        self.index = index
        self.rowHeight = rowHeight
        self.coordinateSpace = coordinateSpace
        self.onToggle = onToggle
        self.onDragChange = onDragChange
        self.onDragEnd = onDragEnd
    }

    public var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(isSelected ? Color.atmusicAmber : Color.atmusicComment.opacity(0.6))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { val in
                        let rawTranslation = val.translation.height
                        let h = max(rowHeight, 1)
                        let delta: Int
                        if rawTranslation >= 0 {
                            delta = Int(floor((rawTranslation + h * 0.25) / h))
                        } else {
                            delta = -Int(floor((-rawTranslation + h * 0.25) / h))
                        }
                        if delta != lastDelta {
                            lastDelta = delta
                            onDragChange(index, delta)
                        }
                    }
                    .onEnded { _ in
                        lastDelta = nil
                        onDragEnd()
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    onToggle()
                }
            )
    }
}
// MARK: - 全局通用多选批量操作浮动栏（四风格自适应，对标 Apple Music 规范）

public struct BatchActionItem: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public var tint: Color? = nil
    public var disabled: Bool = false
    public var action: () -> Void

    public init(
        id: String,
        title: String,
        systemImage: String,
        tint: Color? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.disabled = disabled
        self.action = action
    }
}

public struct UniversalBatchActionBar: View {
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let selectedCount: Int
    var totalCount: Int? = nil
    var onSelectAll: (() -> Void)? = nil
    let actions: [BatchActionItem]

    public init(
        selectedCount: Int,
        totalCount: Int? = nil,
        onSelectAll: (() -> Void)? = nil,
        actions: [BatchActionItem]
    ) {
        self.selectedCount = selectedCount
        self.totalCount = totalCount
        self.onSelectAll = onSelectAll
        self.actions = actions
    }

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var cornerRadius: CGFloat {
        switch uiStyle {
        case .liquid: return 22
        case .clear: return 18
        case .compact: return 14
        case .nativeClean: return 20
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { item in
                Button {
                    ATMusicHaptics.tap()
                    item.action()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 15, weight: .medium))
                        Text(item.title)
                            .font(ATMusicFont.appFont(10, .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(item.tint ?? Color.atmusicLabel)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.disabled)
                .opacity(item.disabled ? 0.4 : 1.0)
            }
        }
        .frame(maxWidth: 580)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
        }
    }
}
