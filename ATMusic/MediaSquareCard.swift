import SwiftUI

// MARK: - 统一方块卡片协议

protocol MediaSquareItem {
    var squareTitle: String { get }
    var squareSubtitle: String { get }
    var squareCoverURL: URL? { get }
    var squareSource: SongSource? { get }
    var squareBadgeText: String? { get }
}

extension Playlist: MediaSquareItem {
    var squareTitle: String { name }
    var squareSubtitle: String {
        if trackCount > 0 {
            return atmusicSongCountText(trackCount)
        }
        if !creatorName.isEmpty {
            return creatorName
        }
        return source.atmusicDisplayName
    }
    var squareCoverURL: URL? { coverURL }
    var squareSource: SongSource? { source }
    var squareBadgeText: String? { nil }
}

extension Album: MediaSquareItem {
    var squareTitle: String { name }
    var squareSubtitle: String {
        if !artistName.isEmpty {
            return artistName
        }
        return source.atmusicDisplayName
    }
    var squareCoverURL: URL? { coverURL }
    var squareSource: SongSource? { source }
    var squareBadgeText: String? {
        if let count = trackCount, count > 0 {
            return atmusicSongCountText(count)
        }
        return nil
    }
}

// MARK: - 统一卡片背景容器（自适应四种全局 UI 风格）

struct MediaSquareCardSurface<S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let shape: S

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    var body: some View {
        switch uiStyle {
        case .liquid:
            ATMusicGlass(shape: shape)
        case .clear:
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.stroke(
                        Color.white.opacity(colorScheme == .dark ? 0.16 : 0.24),
                        lineWidth: 0.8
                    )
                }
        case .compact:
            shape
                .fill(Color.atmusicGlassFill.opacity(0.82))
                .overlay {
                    shape.stroke(
                        Color.atmusicComment.opacity(colorScheme == .dark ? 0.18 : 0.12),
                        lineWidth: 0.6
                    )
                }
        case .nativeClean:
            shape
                .fill(Color(uiColor: .secondarySystemBackground).opacity(colorScheme == .dark ? 0.55 : 0.82))
                .overlay {
                    shape.stroke(
                        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06),
                        lineWidth: 0.5
                    )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06),
                    radius: 5,
                    x: 0,
                    y: 2
                )
        }
    }
}

// MARK: - 统一方块卡片组件

struct MediaSquareCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    let title: String
    let subtitle: String
    let coverURL: URL?
    var source: SongSource? = nil
    var badgeText: String? = nil
    var showSourceBadge: Bool = true
    var fixedCoverSize: CGFloat? = nil
    var titleLineLimit: Int = 1
    var subtitleLineLimit: Int = 1
    var circularCover: Bool = false
    var isMultiSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var cardCornerRadius: CGFloat {
        switch uiStyle {
        case .compact: return 14
        case .nativeClean: return 16
        case .liquid, .clear: return 18
        }
    }

    private var coverCornerRadius: CGFloat {
        switch uiStyle {
        case .compact: return 12
        case .nativeClean: return 8
        case .liquid, .clear: return 14
        }
    }

    private var cardPadding: CGFloat {
        switch uiStyle {
        case .compact: return 6
        case .nativeClean: return 0
        case .liquid, .clear: return 8
        }
    }

    private var cardSpacing: CGFloat {
        switch uiStyle {
        case .compact: return 5
        case .nativeClean: return 6
        case .liquid, .clear: return 7
        }
    }

    private var titleFontSize: CGFloat {
        switch uiStyle {
        case .compact: return 12.5
        case .nativeClean: return 13
        case .liquid, .clear: return 13
        }
    }

    private var subtitleFontSize: CGFloat {
        switch uiStyle {
        case .nativeClean: return 12
        case .compact, .liquid, .clear: return 11
        }
    }

    init(
        title: String,
        subtitle: String,
        coverURL: URL?,
        source: SongSource? = nil,
        badgeText: String? = nil,
        showSourceBadge: Bool = true,
        fixedCoverSize: CGFloat? = nil,
        titleLineLimit: Int = 1,
        subtitleLineLimit: Int = 1,
        circularCover: Bool = false,
        isMultiSelecting: Bool = false,
        isSelected: Bool = false,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.source = source
        self.badgeText = badgeText
        self.showSourceBadge = showSourceBadge
        self.fixedCoverSize = fixedCoverSize
        self.titleLineLimit = titleLineLimit
        self.subtitleLineLimit = subtitleLineLimit
        self.circularCover = circularCover
        self.isMultiSelecting = isMultiSelecting
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
    }

    init(
        item: any MediaSquareItem,
        showSourceBadge: Bool = true,
        fixedCoverSize: CGFloat? = nil,
        titleLineLimit: Int = 1,
        subtitleLineLimit: Int = 1,
        circularCover: Bool = false,
        isMultiSelecting: Bool = false,
        isSelected: Bool = false,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.title = item.squareTitle
        self.subtitle = item.squareSubtitle
        self.coverURL = item.squareCoverURL
        self.source = item.squareSource
        self.badgeText = item.squareBadgeText
        self.showSourceBadge = showSourceBadge
        self.fixedCoverSize = fixedCoverSize
        self.titleLineLimit = titleLineLimit
        self.subtitleLineLimit = subtitleLineLimit
        self.circularCover = circularCover
        self.isMultiSelecting = isMultiSelecting
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
    }

    init(
        playlist: Playlist,
        showSourceBadge: Bool = true,
        fixedCoverSize: CGFloat? = nil,
        titleLineLimit: Int = 1,
        subtitleLineLimit: Int = 1,
        circularCover: Bool = false,
        isMultiSelecting: Bool = false,
        isSelected: Bool = false,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.init(
            item: playlist,
            showSourceBadge: showSourceBadge,
            fixedCoverSize: fixedCoverSize,
            titleLineLimit: titleLineLimit,
            subtitleLineLimit: subtitleLineLimit,
            circularCover: circularCover,
            isMultiSelecting: isMultiSelecting,
            isSelected: isSelected,
            onToggleSelection: onToggleSelection
        )
    }

    init(
        album: Album,
        showSourceBadge: Bool = true,
        fixedCoverSize: CGFloat? = nil,
        titleLineLimit: Int = 1,
        subtitleLineLimit: Int = 1,
        circularCover: Bool = false,
        isMultiSelecting: Bool = false,
        isSelected: Bool = false,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.init(
            item: album,
            showSourceBadge: showSourceBadge,
            fixedCoverSize: fixedCoverSize,
            titleLineLimit: titleLineLimit,
            subtitleLineLimit: subtitleLineLimit,
            circularCover: circularCover,
            isMultiSelecting: isMultiSelecting,
            isSelected: isSelected,
            onToggleSelection: onToggleSelection
        )
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        let content = VStack(alignment: .leading, spacing: cardSpacing) {
            coverView
            textSection
        }
        .padding(cardPadding)
        .background {
            if uiStyle != .nativeClean {
                MediaSquareCardSurface(shape: shape)
            }
        }
        .frame(width: fixedCoverSize.map { $0 + cardPadding * 2 }, alignment: .leading)
        // 简洁风格无卡片底框、内边距为 0：整卡裁剪会啃掉左下角文字，
        // 封面已有自带圆角，这里不再裁；其余风格保持原样
        if uiStyle == .nativeClean {
            content
        } else {
            content.clipShape(shape)
        }
    }

    @ViewBuilder
    private var coverView: some View {
        ZStack(alignment: .bottomTrailing) {
            if let fixedSize = fixedCoverSize {
                CoverImage(url: coverURL, size: fixedSize, cornerRadius: circularCover ? fixedSize / 2 : coverCornerRadius)
                    .frame(width: fixedSize, height: fixedSize)
            } else if circularCover {
                GeometryReader { proxy in
                    CoverImage(url: coverURL, size: proxy.size.width, cornerRadius: proxy.size.width / 2)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            } else {
                CoverImage(url: coverURL, size: 0, cornerRadius: coverCornerRadius, isFlexible: true)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }

            if let badgeText, !badgeText.isEmpty {
                Text(badgeText)
                    .font(ATMusicFont.appFont(9, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(5)
            }

            if isMultiSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.atmusicAmber : Color.white.opacity(0.85))
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(ATMusicFont.appFont(titleFontSize, .medium))
                .foregroundStyle(Color.atmusicLabel)
                .lineLimit(titleLineLimit)
                .multilineTextAlignment(.leading)
                // 预留 titleLineLimit 行高度：一行/两行标题的卡片等高，网格对齐
                .frame(maxWidth: .infinity, minHeight: titleFontSize * 1.35 * CGFloat(titleLineLimit), alignment: .topLeading)

            HStack(spacing: 4) {
                if showSourceBadge, let source {
                    SourceBadgeView(source: source, compact: true)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ATMusicFont.appFont(subtitleFontSize, .regular))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(subtitleLineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
