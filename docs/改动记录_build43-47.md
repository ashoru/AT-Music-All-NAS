# AT Music 迭代改动文档（build 43 → build 47）

> 改动范围：`git diff ecdeb33 5c1a963`（build 43 提交 → build 47 提交）
> 编译验证：Release 无签名构建 **BUILD SUCCEEDED**，产物 `AT-Music-1.8.9-build47-unsigned.ipa`（已同步 iCloud）
> 改动规模：10 个文件，+589 / −390 行

本迭代在 build 43 基础上完成「精选页多平台歌单 + 分页 + 主页改版 + 接口稳定性修复」四轮（build 44/45/46/47）。

---

## 一、改动总览

| 文件 | 涉及 build | 改动主题 |
|---|---|---|
| `ATMusic/RootView.swift` | 44/45/46/47 | 精选页四种歌单模式（聚合/网易/QQ/酷狗）、来源切换、分页、聚合交叉、翻页失败静默停止 |
| `ATMusic/QQMusicAPI.swift` | 45/46/47 | 歌单搜索/广场分页；`searchPlaylists` 改用稳定接口 client_search_cp t=3；新增 `allPlaylists`/`plazaPlaylists` |
| `ATMusic/KugouMusicAPI.swift` | 45/46 | 歌单搜索分页；`recommendPlaylists` 无限分页（移动站兜底） |
| `ATMusic/DiscoverView.swift` | 45/46/47 | 主页“歌单广场”→“最近播放”；推荐栏加 QQ 红心/酷狗私人FM；聚合酷狗漫游显示；QQ 每日推荐卡 2:1 |
| `ATMusic/Components.swift` | 47 | `CoverImage` 支持 width/height 宽高覆盖（2:1 封面） |
| `ATMusic/PlayerView.swift` | 47 | 歌词行距默认 16、滑块范围 4~40 |
| `ATMusic/SectionOrderStore.swift` | 45 | 主页板块默认名“歌单广场”→“最近播放” |
| `ATMusic.xcodeproj/project.pbxproj` | 44-47 | build 号 43→47 |
| `project.yml` | 44-47 | build 号 43→47 |
| `CHANGELOG.md` | 44-47 | build 44-47 版本记录 |

---

## 二、按文件详细改动

### 1. `RootView.swift` — 精选页多平台歌单（核心）
- 新增枚举 `FeaturedSource`：`aggregate / netease / qq / kugou`，含 `title`、`songSource`、`brandImageName`、图标、通用分类 `commonCategories`、`defaultCategories(for:)`。
- `FeaturedView` 左上角改为 `Menu` 切换四种来源，`@AppStorage("atmusic.featuredSource")` 记忆选择。
- `pageSize` 60→40；新增 `header`、`categoryChips`、`playlistGrid`、`playlistSubtitle`。
- 加载分派：`loadNetEase`（歌单广场/精品/分类/搜索，均 offset 分页）、`loadQQ`（"全部/推荐"→`allPlaylists`，其他→搜索）、`loadKugou`（歌单广场/搜索）、`loadAggregate`（三平台并行合并，聚合卡带平台徽标）。
- 聚合歌单交叉显示：`interleave(n,q,k)`，网易→QQ→酷狗→网易…轮流。
- **翻页失败静默停止**：`load(reset:false)` 的 catch 只置 `hasMorePlaylists=false`、不清空不弹错误；仅首屏失败才设 `errorMessage`（修复“断网”提示）。
- `reloadTaskID = "\(featuredSource.rawValue)|\(selectedCategory)|\(query)"` 驱动重载。

### 2. `QQMusicAPI.swift` — 分页 + 稳定接口
- `musicuSearchPayload` 增加 `offset`（`page_num` 随 offset 递增）。
- `searchPlaylists(keyword, limit, offset)` **主用 `client_search_cp` t=3**（与歌曲/专辑同源、不受 musicu 风控），musicu search_type=3 兜底。
- 新增 `allPlaylists(limit, offset)`：QQ 歌单广场，优先 `plazaPlaylists`（musicu GetPlayList，categoryId=-1）→ 首屏回退 `hotPlaylists` → 翻页回退 searchPlaylists（保证无限下拉）。
- 新增私有 `plazaPlaylists`：musicu `playlist.PlayListPlazaServer/GetPlayList`，多路径解析 `v_playlist/playlist`。

### 3. `KugouMusicAPI.swift` — 无限分页
- `searchPlaylists` 增加 `offset`（page = offset/limit+1）。
- `recommendPlaylists(limit, offset)` 重构：首屏优先上游 `special_recommend`（更丰富），后续页用**移动站歌单广场分页** `mobilePlazaPlaylists`（`m.kugou.com/plist/index?json=true&page=N`，可一直下拉），首屏官网正则兜底。
- `upstreamRecommendPlaylists` 增加 `page` 参数。

### 4. `DiscoverView.swift` — 主页改版 + 推荐栏
- 删除原“歌单广场”整套展示（`personalizedSection/singlePersonalizedSection/aggregatePersonalizedSection/aggregatePlaylistCard/aggregatePlaylistGroups/playlistsExpanded/collapsedPlaylistCount` 等）。
- 新增“最近播放”栏：`recentPlayedSongs`（聚合=`player.history`，单平台按 `source` 过滤）+ `recentPlayedSection`（方块横滑）+ `recentSongCard`（点击从该位置播放，聚合带平台徽标）。
- 板块 key `"歌单广场"`→`"最近播放"`；`SectionOrderStore.homeDefaults` 同步改名。
- 推荐栏合并 helper：`mergeDaily([[Song]])`（按 `identityKey` 去重、保序、`prefix(60)`）。
- QQ 推荐栏：`dailySongs = mergeDaily([recommendSongs(30), favoriteSongs()])`；酷狗：`mergeDaily([everydayRecommend(30), personalFM(12)])`。`load()` 与 `fetchSnapshot` 两条路径均同步。
- 聚合“酷狗私人漫游”显示条件改为 `homeProviders.contains(.kugou)`（不再要求“同时不含网易”）。
- `recommendationCard` 新增 `isWide` 参数（2:1，`cardWidth = size*2`）；QQ 每日推荐卡传 `isWide: source == .qq`。

### 5. `Components.swift` — CoverImage 宽高覆盖
- 新增 `width`/`height` 可选参数（默认 nil 用 `size` 正方形）；body 用 `w/h` 计算 frame，支持 2:1 等非正方封面。

### 6. `PlayerView.swift` — 歌词行距
- `@AppStorage("atmusic.lyricSpacing")` 默认 `24`→`16`；滑块范围 `14...40`→`4...40`。

### 7. `SectionOrderStore.swift` — 板块默认名
- `homeDefaults` 由 `["每日推荐", "歌单广场", "排行榜"]` → `["每日推荐", "最近播放", "排行榜"]`。

### 8. 工程文件
- `project.pbxproj` / `project.yml`：`CURRENT_PROJECT_VERSION` 43→47；`CHANGELOG.md`：新增 build 44-47 记录。

---

## 三、按 build 分组

| build | 核心改动 |
|---|---|
| **44** | 精选页四种歌单模式（聚合/网易/QQ/酷狗，左上角切换）；新增 QQ 热门歌单页、酷狗歌单广场页；聚合页三平台并行合并带徽标；记忆来源选择 |
| **45** | QQ/酷狗歌单搜索与分类分页、聚合分页；主页“歌单广场”→“最近播放”（方块横滑，聚合按播放顺序、单平台过滤） |
| **46** | QQ 歌单广场 GetPlayList + 酷狗移动站分页 → 无限下拉；聚合歌单交叉显示（interleave）；推荐栏 QQ 加红心、酷狗加私人 FM |
| **47** | QQ 歌单搜索改 client_search_cp 稳定接口；精选页翻页失败静默停止（不弹“断网”）；QQ 每日推荐卡 2:1；歌词行距 4~40 默认 16；聚合页显示酷狗私人漫游 |

---

## 四、完整 diff 附录

> 可用命令获取：`cd /Users/tangfengjing/gemini/app_music/AT-Music-main && git diff ecdeb33 5c1a963`
> 下面直接给出本迭代的完整 diff（build 43 → build 47）：

```
diff --git a/ATMusic.xcodeproj/project.pbxproj b/ATMusic.xcodeproj/project.pbxproj
index fbbcd1c..1d49c47 100644
--- a/ATMusic.xcodeproj/project.pbxproj
+++ b/ATMusic.xcodeproj/project.pbxproj
@@ -496,7 +496,7 @@
 			buildSettings = {
 				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
 				CODE_SIGN_IDENTITY = "iPhone Developer";
-				CURRENT_PROJECT_VERSION = 43;
+				CURRENT_PROJECT_VERSION = 47;
 				INFOPLIST_FILE = ATMusic/Info.plist;
 				LD_RUNPATH_SEARCH_PATHS = (
 					"$(inherited)",
@@ -571,7 +571,7 @@
 			buildSettings = {
 				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
 				CODE_SIGN_IDENTITY = "iPhone Developer";
-				CURRENT_PROJECT_VERSION = 43;
+				CURRENT_PROJECT_VERSION = 47;
 				INFOPLIST_FILE = ATMusic/Info.plist;
 				LD_RUNPATH_SEARCH_PATHS = (
 					"$(inherited)",
diff --git a/ATMusic/Components.swift b/ATMusic/Components.swift
index a5497da..1d73423 100644
--- a/ATMusic/Components.swift
+++ b/ATMusic/Components.swift
@@ -764,6 +764,9 @@ struct CoverImage: View {
     var cornerRadius: CGFloat = 12
     /// 封面未加载时的提示文字（播放器大封面用：等待开始播放）；nil 显示中性图标
     var emptyHint: String? = nil
+    /// 独立宽高覆盖（默认 nil 用 size 正方形；宽版 2:1 卡片传 width/height）
+    var width: CGFloat? = nil
+    var height: CGFloat? = nil
     @StateObject private var loader = ATMusicCoverImageLoader()
 
     private var displayedImage: UIImage? {
@@ -775,15 +778,17 @@ struct CoverImage: View {
     // 布局尺寸完全由外层固定容器决定；AsyncImage 只放在 overlay 中渲染，
     // 图片加载完成与否都不会改变任何布局尺寸（根治"封面加载后错乱"）。
     var body: some View {
-        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
+        let w = width ?? size
+        let h = height ?? size
+        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
             .fill(Color.atmusicGlassFill)
-            .frame(width: size, height: size)
+            .frame(width: w, height: h)
             .overlay {
                 if let displayedImage {
                     Image(uiImage: displayedImage)
                         .resizable()
                         .scaledToFill()
-                        .frame(width: size, height: size)
+                        .frame(width: w, height: h)
                         .clipped()
                 } else {
                     placeholderIcon
diff --git a/ATMusic/DiscoverView.swift b/ATMusic/DiscoverView.swift
index 900cec2..bfe3245 100644
--- a/ATMusic/DiscoverView.swift
+++ b/ATMusic/DiscoverView.swift
@@ -58,10 +58,6 @@ struct DiscoverView: View {
 
     @State private var qqTopLists: [QQTopInfo] = []
     @State private var kugouTopLists: [KugouTopInfo] = []
-    /// 歌单广场展开状态：收起显示前 6，展开显示全部
-    @State private var playlistsExpanded = false
-    /// 聚合首页各平台歌单独立展开；展开后直接在当前页面双列显示。
-    @State private var expandedAggregatePlaylistSources = Set<SongSource>()
     /// 首页加载去重：SwiftUI 视图刷新时 .task 可能被重复触发，避免网络请求风暴。
     @State private var activeLoadKey: String?
     @State private var lastLoadedKey = ""
@@ -118,10 +114,8 @@ struct DiscoverView: View {
                                     }
                                 case "排行榜":
                                     if hasRankData { topListsSection }
-                                case "歌单广场":
-                                    if isHomeAggregate || !personalized.isEmpty {
-                                        personalizedSection
-                                    }
+                                case "最近播放":
+                                    recentPlayedSection
                                 default:
                                     EmptyView()
                                 }
@@ -649,7 +643,7 @@ struct DiscoverView: View {
                         }
                     }
 
-                    if !homeProviders.contains(.netease), homeProviders.contains(.kugou) {
+                    if homeProviders.contains(.kugou) {
                         recommendationCard(
                             title: "私人漫游",
                             subtitle: "酷狗音乐 · 个性推荐",
@@ -679,7 +673,8 @@ struct DiscoverView: View {
                         icon: "calendar",
                         coverURL: dailySongs.first?.coverURL,
                         gradient: [Color(red: 0.95, green: 0.36, blue: 0.28), Color(red: 0.96, green: 0.68, blue: 0.30)],
-                        loadingKey: nil
+                        loadingKey: nil,
+                        isWide: source == .qq
                     ) {
                         openDailyRecommendations()
                     }
@@ -741,13 +736,16 @@ struct DiscoverView: View {
         gradient: [Color],
         loadingKey: String?,
         cardSize: CGFloat? = nil,
+        isWide: Bool = false,
         action: @escaping () -> Void
     ) -> some View {
         let resolvedCardSize = cardSize ?? (isNativeClean ? 160 : 168)
+        let cardWidth = isWide ? resolvedCardSize * 2 : resolvedCardSize
+        let cardHeight = resolvedCardSize
         return Button(action: action) {
             ZStack(alignment: .bottomLeading) {
                 if let coverURL {
-                    CoverImage(url: coverURL, size: resolvedCardSize, cornerRadius: isNativeClean ? 16 : 18)
+                    CoverImage(url: coverURL, size: resolvedCardSize, cornerRadius: isNativeClean ? 16 : 18, width: cardWidth, height: cardHeight)
                         .overlay {
                             LinearGradient(
                                 colors: [.black.opacity(0.05), .black.opacity(0.62)],
@@ -758,6 +756,7 @@ struct DiscoverView: View {
                 } else {
                     RoundedRectangle(cornerRadius: isNativeClean ? 16 : 18, style: .continuous)
                         .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
+                        .frame(width: cardWidth, height: cardHeight)
                         .overlay(alignment: .topTrailing) {
                             Circle()
                                 .fill(.white.opacity(0.16))
@@ -797,7 +796,7 @@ struct DiscoverView: View {
                 }
                 .padding(14)
             }
-            .frame(width: resolvedCardSize, height: resolvedCardSize)
+            .frame(width: cardWidth, height: cardHeight)
             .clipShape(RoundedRectangle(cornerRadius: isNativeClean ? 16 : 18, style: .continuous))
             .shadow(color: Color.black.opacity(isNativeClean ? 0.06 : 0.12), radius: 16, x: 0, y: 8)
             .contentShape(RoundedRectangle(cornerRadius: isNativeClean ? 16 : 18, style: .continuous))
@@ -937,252 +936,77 @@ struct DiscoverView: View {
         }
     }
 
-    // MARK: - 歌单广场（官方分类 + 双列网格）
+    // MARK: - 最近播放（原“歌单广场”栏改为最近播放歌曲，方块横滑）
 
-
-    @ViewBuilder
-    private var personalizedSection: some View {
-        if isHomeAggregate {
-            aggregatePersonalizedSection
-        } else {
-            singlePersonalizedSection
+    /// 当前主页显示的最近播放歌曲：
+    /// 聚合页按播放顺序展示所有平台的最近播放；单平台主页只显示本平台的最近播放。
+    /// 合并多个歌曲数组并按 identityKey 去重，保持输入顺序（推荐栏合并每日推荐 / 红心 / 私人FM）。
+    private static func mergeDaily(_ arrays: [[Song]]) -> [Song] {
+        var seen = Set<String>()
+        var result: [Song] = []
+        for arr in arrays {
+            for song in arr where seen.insert(song.identityKey).inserted {
+                result.append(song)
+            }
         }
+        return Array(result.prefix(60))
+    }
+    private var recentPlayedSongs: [Song] {
+        if isHomeAggregate { return player.history }
+        let songSource = source.songSource
+        return player.history.filter { $0.source == songSource }
     }
 
-    private var singlePersonalizedSection: some View {
+    @ViewBuilder
+    private var recentPlayedSection: some View {
         VStack(alignment: .leading, spacing: 12) {
-            SectionHeader(title: playlistSectionTitle)
-            if visiblePersonalizedPlaylists.isEmpty {
-                EmptyStateView(icon: "music.note.list", text: playlistEmptyText)
-            } else if isNativeClean && !playlistsExpanded {
+            SectionHeader(title: "最近播放")
+            if recentPlayedSongs.isEmpty {
+                EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无最近播放")
+            } else {
                 ScrollView(.horizontal, showsIndicators: false) {
-                    LazyHStack(spacing: 16) {
-                        ForEach(visiblePersonalizedPlaylists, id: \.identityKey) { (playlist: Playlist) in
-                            Button {
-                                ATMusicHaptics.tap()
-                                openRoute(DiscoverRoute.playlist(playlist))
-                            } label: {
-                                VStack(alignment: .leading, spacing: 8) {
-                                    CoverImage(url: playlist.coverURL, size: 166, cornerRadius: 16)
-                                    HStack(spacing: 6) {
-                                        Text(playlist.name)
-                                            .font(ATMusicFont.appFont(15, .bold))
-                                            .foregroundStyle(Color.primary)
-                                            .lineLimit(2)
-                                            .multilineTextAlignment(.leading)
-                                        SourceBadgeView(source: playlist.source, compact: true)
-                                    }
-                                    .frame(width: 166, alignment: .leading)
-                                    if playlist.trackCount > 0 {
-                                        Text(atmusicSongCountText(playlist.trackCount))
-                                            .font(ATMusicFont.appFont(12, .medium))
-                                            .foregroundStyle(Color.secondary)
-                                            .lineLimit(1)
-                                    }
-                                }
-                                .frame(width: 166, alignment: .leading)
-                            }
-                            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
+                    LazyHStack(spacing: 14) {
+                        ForEach(Array(recentPlayedSongs.enumerated()), id: \.element.identityKey) { index, song in
+                            recentSongCard(song, index: index)
                         }
                     }
                     .padding(.vertical, 2)
+                    .padding(.trailing, isNativeClean ? 24 : 4)
                 }
-            } else {
-                LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 150, maxWidth: 240, spacing: 14), spacing: 14) {
-                    ForEach(visiblePersonalizedPlaylists, id: \.identityKey) { playlist in
-                        Button {
-                            openRoute(DiscoverRoute.playlist(playlist))
-                        } label: {
-                            VStack(alignment: .leading, spacing: 6) {
-                                CoverImage(url: playlist.coverURL, size: 144, cornerRadius: 18)
-                                    .frame(maxWidth: .infinity)
-                                HStack(spacing: 6) {
-                                    Text(playlist.name)
-                                        .font(ATMusicFont.appFont(12, .medium))
-                                        .foregroundStyle(Color.atmusicLabel)
-                                        .lineLimit(2)
-                                        .multilineTextAlignment(.leading)
-                                    SourceBadgeView(source: playlist.source, compact: true)
-                                }
-                            }
-                            .padding(8)
-                            .frame(maxWidth: .infinity, alignment: .leading)
-                            .background {
-                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
-                            }
-                        }
-                        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
-                    }
-                }
-            }
-            if personalized.count > collapsedPlaylistCount {
-                Button {
-                    ATMusicHaptics.select()
-                    withAnimation {
-                        playlistsExpanded.toggle()
-                    }
-                } label: {
-                    HStack(spacing: 6) {
-                        Text(playlistsExpanded
-                             ? atmusicLocalized("收起歌单广场", "Collapse Playlist Square")
-                             : atmusicLocalized("展开全部（\(personalized.count)）", "Show all (\(personalized.count))"))
-                            .font(ATMusicFont.appFont(13, .semibold))
-                        Image(systemName: playlistsExpanded ? "chevron.up" : "chevron.down")
-                            .font(.system(size: 11, weight: .semibold))
-                    }
-                    .foregroundStyle(Color.atmusicAmber)
-                    .frame(maxWidth: .infinity)
-                    .padding(.vertical, 11)
-                    .background {
-                        if isNativeClean {
-                            Capsule().fill(Color.primary.opacity(0.045))
-                        } else {
-                            ATMusicGlass(shape: Capsule())
-                        }
-                    }
-                    .contentShape(Rectangle())
-                }
-                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
+                .atmusicScrollIndicatorsHidden()
             }
         }
     }
 
-    /// 聚合首页的歌单按音源分组，每个平台独占一行，避免不同平台的歌单混排。
-    private var aggregatePersonalizedSection: some View {
-        VStack(alignment: .leading, spacing: 22) {
-            SectionHeader(title: "聚合歌单")
-            if aggregatePlaylistGroups.isEmpty {
-                EmptyStateView(icon: "music.note.list", text: playlistEmptyText)
-            } else {
-                ForEach(Array(aggregatePlaylistGroups.enumerated()), id: \.element.0) { _, group in
-                    let isExpanded = expandedAggregatePlaylistSources.contains(group.0)
-                    VStack(alignment: .leading, spacing: 10) {
-                        Button {
-                            ATMusicHaptics.select()
-                            if isExpanded {
-                                expandedAggregatePlaylistSources.remove(group.0)
-                            } else {
-                                expandedAggregatePlaylistSources.insert(group.0)
-                            }
-                        } label: {
-                            HStack(spacing: 8) {
-                                Text(aggregateSourceTitle(group.0))
-                                    .font(ATMusicFont.appFont(16, .bold))
-                                    .foregroundStyle(Color.atmusicLabel)
-                                Spacer(minLength: 8)
-                                SourceBadgeView(source: group.0, compact: true)
-                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
-                                    .font(.system(size: 12, weight: .bold))
-                                    .foregroundStyle(Color.atmusicComment)
-                                    .frame(width: 28, height: 28)
-                                    .background(Color.atmusicSecondary.opacity(0.10), in: Circle())
-                            }
-                        }
-                        .buttonStyle(.plain)
-
-                        if isExpanded {
-                            LazyVGrid(
-                                columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 150, maxWidth: 240, spacing: 14),
-                                spacing: 18
-                            ) {
-                                ForEach(group.1, id: \.identityKey) { playlist in
-                                    aggregatePlaylistCard(playlist, expanded: true)
-                                }
-                            }
-                        } else {
-                            ScrollView(.horizontal, showsIndicators: false) {
-                                LazyHStack(spacing: 14) {
-                                    ForEach(Array(group.1.prefix(collapsedPlaylistCount).enumerated()), id: \.element.identityKey) { _, playlist in
-                                        aggregatePlaylistCard(playlist, expanded: false)
-                                    }
-                                }
-                                .padding(.vertical, 2)
-                            }
-                            .padding(.trailing, isNativeClean ? -24 : 0)
-                        }
-                    }
-                }
-                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
-            }
-        }
-    }
-
-    @ViewBuilder
-    private func aggregatePlaylistCard(_ playlist: Playlist, expanded: Bool) -> some View {
-        let size: CGFloat = expanded ? 164 : (isNativeClean ? 156 : 136)
-        Button {
+    private func recentSongCard(_ song: Song, index: Int) -> some View {
+        let size: CGFloat = isNativeClean ? 156 : 136
+        return Button {
             ATMusicHaptics.tap()
-            openRoute(DiscoverRoute.playlist(playlist))
+            player.play(songs: recentPlayedSongs, startAt: index)
         } label: {
             VStack(alignment: .leading, spacing: 7) {
-                CoverImage(url: playlist.coverURL, size: size, cornerRadius: 16)
-                Text(playlist.name)
-                    .font(ATMusicFont.appFont(isNativeClean ? 14 : 12, .medium))
-                    .foregroundStyle(Color.atmusicLabel)
-                    .lineLimit(2)
-                    .frame(width: size, alignment: .leading)
-                if playlist.trackCount > 0 {
-                    Text(atmusicSongCountText(playlist.trackCount))
-                        .font(ATMusicFont.appFont(11, .medium))
-                        .foregroundStyle(Color.atmusicComment)
+                CoverImage(url: song.coverURL, size: size, cornerRadius: 16)
+                HStack(spacing: 5) {
+                    Text(song.name)
+                        .font(ATMusicFont.appFont(isNativeClean ? 14 : 12, .medium))
+                        .foregroundStyle(Color.atmusicLabel)
                         .lineLimit(1)
+                    if isHomeAggregate {
+                        SourceBadgeView(source: song.source, compact: true)
+                    }
                 }
+                .frame(width: size, alignment: .leading)
+                Text(song.artists)
+                    .font(ATMusicFont.appFont(isNativeClean ? 12 : 11, .medium))
+                    .foregroundStyle(Color.atmusicComment)
+                    .lineLimit(1)
+                    .frame(width: size, alignment: .leading)
             }
             .frame(width: size, alignment: .leading)
         }
         .buttonStyle(GlassPressButtonStyle(scale: 0.96))
     }
 
-    private var aggregatePlaylistGroups: [(SongSource, [Playlist])] {
-        let order: [SongSource] = [.netease, .qq, .kugou, .synology]
-        let enabledSources = Set(homeProviders.map(\.songSource))
-        var grouped: [SongSource: [Playlist]] = [:]
-        for item in personalized {
-            if enabledSources.contains(item.source) {
-                grouped[item.source, default: []].append(item)
-            }
-        }
-        return order.compactMap { source in
-            guard let items = grouped[source], !items.isEmpty else { return nil }
-            return (source, items)
-        }
-    }
-
-    private func aggregateSourceTitle(_ source: SongSource) -> String {
-        switch source {
-        case .netease: return "网易云音乐"
-        case .qq: return "QQ音乐"
-        case .kugou: return "酷狗音乐"
-        case .local: return "本地音乐"
-        case .synology: return "群晖 NAS"
-        }
-    }
-
-    private var playlistSectionTitle: String {
-        if isHomeAggregate { return "聚合歌单" }
-        switch source {
-        case .netease: return "推荐歌单"
-        case .qq: return "QQ音乐热门歌单"
-        case .kugou: return "歌单广场"
-        case .synology: return "群晖 Audio Station"
-        }
-    }
-
-    private var playlistEmptyText: String {
-        if isHomeAggregate { return "暂时没有获取到聚合歌单" }
-        switch source {
-        case .netease: return "推荐歌单暂时没有内容"
-        case .qq: return "QQ音乐热门歌单暂未加载成功\n下拉刷新可重新获取"
-        case .kugou: return "歌单广场暂时没有内容"
-        case .synology: return "群晖音乐库请在音乐库页面查看"
-        }
-    }
-
-    private var collapsedPlaylistCount: Int { 6 }
-
-    private var visiblePersonalizedPlaylists: [Playlist] {
-        playlistsExpanded ? personalized : Array(personalized.prefix(collapsedPlaylistCount))
-    }
 
     // MARK: - 动作
 
@@ -1264,7 +1088,9 @@ struct DiscoverView: View {
             case .qq:
                 group.addTask {
                     var part = DiscoverCache.Snapshot()
-                    part.dailySongs = (try? await QQMusicAPI.shared.recommendSongs(limit: 30)) ?? []
+                    let rec = (try? await QQMusicAPI.shared.recommendSongs(limit: 30)) ?? []
+                    let fav = (try? await QQMusicAPI.shared.favoriteSongs()) ?? []
+                    part.dailySongs = Self.mergeDaily([rec, fav])
                     return part
                 }
                 group.addTask {
@@ -1281,8 +1107,9 @@ struct DiscoverView: View {
             case .kugou:
                 group.addTask {
                     var part = DiscoverCache.Snapshot()
+                    let fm = (try? await KugouMusicAPI.shared.personalFM(limit: 12)) ?? []
                     if let songs = try? await KugouMusicAPI.shared.everydayRecommend(limit: 30), !songs.isEmpty {
-                        part.dailySongs = songs
+                        part.dailySongs = Self.mergeDaily([songs, fm])
                     } else {
                         part.dailySongs = (try? await KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: 30)) ?? []
                     }
@@ -1506,11 +1333,12 @@ struct DiscoverView: View {
             async let a: [Song] = (try? await QQMusicAPI.shared.recommendSongs(limit: 30)) ?? []
             async let b: [QQTopInfo] = (try? await QQMusicAPI.shared.topLists()) ?? []
             async let c: [Playlist] = (try? await QQMusicAPI.shared.hotPlaylists(limit: 18)) ?? []
-            let (dr, tl, pp) = await (a, b, c)
+            async let d: [Song] = (try? await QQMusicAPI.shared.favoriteSongs()) ?? []
+            let (dr, tl, pp, fav) = await (a, b, c, d)
             if pp.isEmpty {
                 ATMusicLogger.shared.log("QQ音乐热门歌单为空：保留板块并显示空状态", level: .warn)
             }
-            snapshot.dailySongs = dr
+            snapshot.dailySongs = Self.mergeDaily([dr, fav])
             snapshot.qqTopLists = tl
             snapshot.personalized = pp
         case .netease:
@@ -1548,8 +1376,9 @@ struct DiscoverView: View {
     }
 
     private func loadKugouDailySongs(limit: Int) async -> [Song] {
+        let fm = (try? await KugouMusicAPI.shared.personalFM(limit: 12)) ?? []
         if let songs = try? await KugouMusicAPI.shared.everydayRecommend(limit: limit), !songs.isEmpty {
-            return songs
+            return Self.mergeDaily([songs, fm])
         }
         return (try? await KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: limit)) ?? []
     }
diff --git a/ATMusic/KugouMusicAPI.swift b/ATMusic/KugouMusicAPI.swift
index d759c4c..0b7d2b8 100644
--- a/ATMusic/KugouMusicAPI.swift
+++ b/ATMusic/KugouMusicAPI.swift
@@ -285,14 +285,14 @@ final class KugouMusicAPI {
     }
 
     /// 酷狗公开歌单搜索。与歌曲搜索使用独立的 special 接口，返回结果按酷狗默认热度/相关性排序。
-    func searchPlaylists(keyword: String, limit: Int = 30) async throws -> [Playlist] {
+    func searchPlaylists(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Playlist] {
         // mobilecdn.kugou.com 的证书在部分 iOS 网络环境下与域名不匹配；
         // 同一接口通过 mobileservice.kugou.com 提供，返回结构一致且可正常校验证书。
         var components = URLComponents(string: "https://mobileservice.kugou.com/api/v3/search/special")!
         components.queryItems = [
             URLQueryItem(name: "format", value: "json"),
             URLQueryItem(name: "keyword", value: keyword),
-            URLQueryItem(name: "page", value: "1"),
+            URLQueryItem(name: "page", value: "\(max(1, offset / max(limit, 1) + 1))"),
             URLQueryItem(name: "pagesize", value: "\(min(max(limit, 1), 100))"),
         ]
         guard let url = components.url else {
@@ -841,15 +841,29 @@ final class KugouMusicAPI {
     }
 
     /// 酷狗官方歌单广场（移动站点 JSON）。
-    func recommendPlaylists(limit: Int = 12) async throws -> [Playlist] {
-        if let upstream = try? await upstreamRecommendPlaylists(limit: limit), !upstream.isEmpty {
+    /// 酷狗歌单广场：支持 offset 分页，可一直下拉。
+    /// 首屏优先上游 special_recommend（更丰富），后续页用移动站歌单广场分页兜底。
+    func recommendPlaylists(limit: Int = 12, offset: Int = 0) async throws -> [Playlist] {
+        let page = max(1, offset / max(limit, 1) + 1)
+        if page == 1,
+           let upstream = try? await upstreamRecommendPlaylists(limit: limit, page: page),
+           !upstream.isEmpty {
             ATMusicLogger.shared.log("酷狗 special_recommend：返回 \(upstream.count) 个歌单", level: .debug)
             return upstream
         }
-        if let playlists = try? await officialWebPlaylists(limit: limit), !playlists.isEmpty {
+        if let playlists = try? await mobilePlazaPlaylists(limit: limit, page: page), !playlists.isEmpty {
+            return playlists
+        }
+        // 首屏最后一招：官网正则兜底
+        if page == 1, let playlists = try? await officialWebPlaylists(limit: limit), !playlists.isEmpty {
             return playlists
         }
-        guard let url = URL(string: "https://m.kugou.com/plist/index?json=true&page=1") else {
+        return []
+    }
+
+    /// 酷狗移动站歌单广场 JSON 分页接口（可一直下拉）。
+    private func mobilePlazaPlaylists(limit: Int, page: Int) async throws -> [Playlist] {
+        guard let url = URL(string: "https://m.kugou.com/plist/index?json=true&page=\(page)") else {
             throw NetEaseError.unknown("酷狗歌单广场地址无效")
         }
         let json = try await getJSON(url, ua: Self.browserUA)
@@ -872,7 +886,7 @@ final class KugouMusicAPI {
         }
     }
 
-    private func upstreamRecommendPlaylists(limit: Int) async throws -> [Playlist] {
+    private func upstreamRecommendPlaylists(limit: Int, page: Int = 1) async throws -> [Playlist] {
         let auth = KugouMusicAuth.shared
         let clientTime = Int(Date().timeIntervalSince1970)
         let specialRecommend: [String: Any] = [
@@ -896,7 +910,7 @@ final class KugouMusicAPI {
                 "clienttime": clientTime,
                 "userid": Int(auth.userId) ?? 0,
                 "module_id": 1,
-                "page": 1,
+                "page": page,
                 "pagesize": min(max(limit, 1), 30),
                 "key": upstreamParamsKey("\(clientTime)"),
                 "special_recommend": specialRecommend,
diff --git a/ATMusic/PlayerView.swift b/ATMusic/PlayerView.swift
index 9073929..6ee06ad 100644
--- a/ATMusic/PlayerView.swift
+++ b/ATMusic/PlayerView.swift
@@ -3703,7 +3703,7 @@ struct PlayerSettingsSheet: View {
     @AppStorage("atmusic.progressAccentHex") private var progressAccentHex = ""
     @AppStorage("atmusic.playback.autoSkipOnFailure") private var autoSkipOnFailure = true
     @AppStorage("atmusic.lyricFontSize") private var fontSize = 17
-    @AppStorage("atmusic.lyricSpacing") private var lineSpacing = 24
+    @AppStorage("atmusic.lyricSpacing") private var lineSpacing = 16
     @AppStorage("atmusic.lyricGlow") private var glowLevel = 1
     @AppStorage("atmusic.lyricColor") private var currentColorRaw = "accent"
     @AppStorage("atmusic.lyricDimColor") private var dimColorRaw = "dim"
@@ -4438,7 +4438,7 @@ struct PlayerSettingsSheet: View {
             settingSlider("歌词行距", valueText: "\(lineSpacing) pt") {
                 ATMusicInteractiveValueSlider(
                     value: Binding(get: { CGFloat(lineSpacing) }, set: { lineSpacing = Int($0.rounded()) }),
-                    range: 14...40,
+                    range: 4...40,
                     step: 1,
                     accessibilityLabel: "歌词行距"
                 )
diff --git a/ATMusic/QQMusicAPI.swift b/ATMusic/QQMusicAPI.swift
index 44840a1..4a9f313 100644
--- a/ATMusic/QQMusicAPI.swift
+++ b/ATMusic/QQMusicAPI.swift
@@ -170,8 +170,9 @@ final class QQMusicAPI {
             ?? value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
     }
 
-    private func musicuSearchPayload(keyword: String, limit: Int, type: QQSearchType) -> [String: Any] {
-        [
+    private func musicuSearchPayload(keyword: String, limit: Int, offset: Int = 0, type: QQSearchType) -> [String: Any] {
+        let page = max(1, offset / max(limit, 1) + 1)
+        return [
             "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
             "req_1": [
                 "module": "music.search.SearchCgiService",
@@ -179,7 +180,7 @@ final class QQMusicAPI {
                 "param": [
                     "query": keyword,
                     "num_per_page": limit,
-                    "page_num": 1,
+                    "page_num": page,
                     "search_type": type.rawValue,
                     "grp": 1,
                 ],
@@ -348,10 +349,25 @@ final class QQMusicAPI {
         return albums
     }
 
-    /// 搜索公开歌单（musicu search_type=3）。不同 QQ 客户端版本会把列表放在
-    /// playlist.list 或 v_playlist.list，统一做多路径解析，避免聚合搜索只返回歌曲。
-    func searchPlaylists(keyword: String, limit: Int = 30) async throws -> [Playlist] {
-        let json = try await musicu(musicuSearchPayload(keyword: keyword, limit: limit, type: .playlist))
+    /// 搜索公开歌单。主用 client_search_cp t=3（与歌曲/专辑搜索同源、数据中心/移动网络均可用，
+    /// 不受 musicu 风控影响，保证精选页歌单可无限翻页）；musicu search_type=3 作为兜底。
+    func searchPlaylists(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Playlist] {
+        let pageSize = max(limit, 1)
+        let page = max(offset, 0) / pageSize + 1
+        if let url = clientSearchURL(keyword: keyword, limit: pageSize, type: 3, page: page),
+           let json = try? await get(url.absoluteString, referer: "https://y.qq.com/portal/player.html") {
+            let data = json["data"] as? [String: Any] ?? [:]
+            let playlistDict = data["playlist"] as? [String: Any] ?? [:]
+            let list = (playlistDict["list"] as? [[String: Any]]) ?? (data["playlist"] as? [[String: Any]] ?? [])
+            if !list.isEmpty {
+                var seen = Set<Int>()
+                return list.compactMap { item in
+                    guard let playlist = Self.searchPlaylist(from: item), seen.insert(playlist.id).inserted else { return nil }
+                    return playlist
+                }
+            }
+        }
+        let json = try await musicu(musicuSearchPayload(keyword: keyword, limit: limit, offset: offset, type: .playlist))
         let paths = [
             ["req_1", "data", "body", "playlist", "list"],
             ["req_1", "data", "body", "v_playlist", "list"],
@@ -407,6 +423,59 @@ final class QQMusicAPI {
         return playlist
     }
 
+    /// QQ 歌单广场分页（musicu GetPlayList，categoryId=-1 全部），供精选页无限下拉。
+    /// 优先使用官方歌单广场接口；接口异常时首屏回退热门歌单，翻页回退搜索歌单。
+    func allPlaylists(limit: Int = 40, offset: Int = 0) async throws -> [Playlist] {
+        if let plaza = try? await plazaPlaylists(limit: limit, offset: offset), !plaza.isEmpty {
+            return plaza
+        }
+        if offset == 0 {
+            return try await hotPlaylists(limit: limit)
+        }
+        return try await searchPlaylists(keyword: "热门", limit: limit, offset: offset)
+    }
+
+    /// QQ 音乐馆「歌单广场」分页接口（musicu playlist.PlayListPlazaServer / GetPlayList）。
+    private func plazaPlaylists(limit: Int, offset: Int) async throws -> [Playlist] {
+        let payload: [String: Any] = [
+            "getPlayList": [
+                "module": "playlist.PlayListPlazaServer",
+                "method": "GetPlayList",
+                "param": [
+                    "num": min(max(limit, 1), 50),
+                    "start": offset,
+                    "order": 1,
+                    "categoryId": -1
+                ]
+            ]
+        ]
+        let json = try await musicu(payload)
+        let paths: [[String]] = [
+            ["getPlayList", "data", "v_playlist"],
+            ["getPlayList", "data", "playlist"],
+            ["getPlayList", "data", "v_playlist", "list"],
+        ]
+        var rows: [[String: Any]] = []
+        for path in paths {
+            var current: Any = json
+            for key in path {
+                guard let dict = current as? [String: Any], let next = dict[key] else {
+                    current = NSNull()
+                    break
+                }
+                current = next
+            }
+            if let list = current as? [[String: Any]], !list.isEmpty {
+                rows = list
+                break
+            }
+        }
+        var seen = Set<Int>()
+        return rows.compactMap { item in
+            guard let playlist = Self.searchPlaylist(from: item), seen.insert(playlist.id).inserted else { return nil }
+            return playlist
+        }
+    }
     /// QQ 音乐热搜词
     func hotKeys(limit: Int = 10) async throws -> [String] {
         let url = "https://c.y.qq.com/splcloud/fcgi-bin/gethotkey.fcg?format=json&inCharset=utf8&outCharset=utf-8"
diff --git a/ATMusic/RootView.swift b/ATMusic/RootView.swift
index 3cce337..5be7637 100644
--- a/ATMusic/RootView.swift
+++ b/ATMusic/RootView.swift
@@ -350,28 +350,109 @@ struct PlatformPickerSheet: View {
     }
 }
 
-/// 网易云风格的“精选”主页面：顶部搜索歌单、分类胶囊和双列歌单网格。
+/// 精选页歌单数据来源：可切换的「聚合 / 网易云 / QQ / 酷狗」四种歌单浏览模式。
+/// 与主页（DiscoverView）左上角平台切换保持一致：左上角标题即当前来源，点击弹出切换菜单。
+enum FeaturedSource: String, CaseIterable, Identifiable, Hashable {
+    case aggregate
+    case netease
+    case qq
+    case kugou
+
+    var id: String { rawValue }
+
+    var title: String {
+        switch self {
+        case .aggregate: return "聚合"
+        case .netease: return "网易云音乐"
+        case .qq: return "QQ音乐"
+        case .kugou: return "酷狗音乐"
+        }
+    }
+
+    /// 单平台来源对应的歌单 source；聚合模式为 nil。
+    var songSource: SongSource? {
+        switch self {
+        case .aggregate: return nil
+        case .netease: return .netease
+        case .qq: return .qq
+        case .kugou: return .kugou
+        }
+    }
+
+    var brandImageName: String? {
+        switch self {
+        case .aggregate: return nil
+        case .netease: return "BrandNetease"
+        case .qq: return "BrandQQ"
+        case .kugou: return "BrandKugou"
+        }
+    }
+
+    /// 聚合模式在左上角使用的系统图标（无品牌图）。
+    var aggregateIcon: String { "square.stack.3d.up.fill" }
+
+    /// 切换菜单里使用的系统图标。
+    var menuIcon: String {
+        switch self {
+        case .aggregate: return "square.stack.3d.up.fill"
+        case .netease: return "cloud.fill"
+        case .qq: return "play.rectangle.fill"
+        case .kugou: return "music.note"
+        }
+    }
+
+    /// 精选页通用分类（非网易云来源不再请求网易云远程分类，直接使用这份固定分类）。
+    static let commonCategories = [
+        "华语", "欧美", "日语", "韩语", "粤语", "小语种",
+        "流行", "摇滚", "民谣", "电子", "舞曲", "说唱", "轻音乐", "爵士", "乡村", "古典", "民族", "英伦", "金属", "朋克", "蓝调", "雷鬼", "拉丁", "另类/独立", "世界音乐", "New Age", "古风", "BGM", "嘻哈", "网络歌曲", "DJ", "R&B/Soul",
+        "清晨", "夜晚", "学习", "工作", "午休", "下午茶", "地铁", "驾车", "运动", "旅行", "散步", "酒吧",
+        "怀旧", "清新", "浪漫", "性感", "伤感", "治愈", "放松", "孤独", "感动", "兴奋", "快乐", "安静", "思念",
+        "综艺", "影视原声", "ACG", "儿童", "校园", "游戏", "翻唱", "器乐", "亲子", "公益", "婚礼", "派对", "音乐播客"
+    ]
+
+    /// 各来源的默认分类胶囊（含固定入口：全部 / 推荐歌单 / 精品歌单）。
+    static func defaultCategories(for source: FeaturedSource) -> [String] {
+        var merged: [String] = ["全部", "推荐歌单", "精品歌单"]
+        for name in commonCategories {
+            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
+            guard !trimmed.isEmpty, !merged.contains(trimmed) else { continue }
+            merged.append(trimmed)
+        }
+        return merged
+    }
+}
+
+/// 网易云风格的“精选”主页面：左上角可在「聚合 / 网易云 / QQ / 酷狗」四种歌单之间切换，
+/// 支持顶部搜索歌单、分类胶囊和双列歌单网格，下拉刷新；网易云来源支持分页加载。
 struct FeaturedView: View {
     var onOpenProfile: () -> Void = {}
     @EnvironmentObject private var theme: ThemeStore
     @EnvironmentObject private var auth: AuthStore
     @EnvironmentObject private var player: PlayerManager
 
-    @State private var categories = ["全部", "推荐歌单", "精品歌单"]
+    @AppStorage("atmusic.featuredSource") private var featuredSourceRaw = FeaturedSource.netease.rawValue
+
+    @State private var categories = FeaturedSource.defaultCategories(for: .netease)
     @State private var selectedCategory = "全部"
     @State private var query = ""
     @State private var playlists: [Playlist] = []
     @State private var isLoading = true
     @State private var isLoadingMore = false
     @State private var errorMessage: String?
-    @State private var didLoadCategories = false
     @State private var nextOffset = 0
     @State private var hasMorePlaylists = true
 
-    private let pageSize = 60
+    private let pageSize = 40
+
+    private var featuredSource: FeaturedSource {
+        FeaturedSource(rawValue: featuredSourceRaw) ?? .netease
+    }
+
+    private var isAggregate: Bool { featuredSource == .aggregate }
 
-    private var visiblePlaylists: [Playlist] {
-        playlists
+    /// 来源 / 分类 / 关键词任一变化都会触发重载。
+    private var reloadTaskID: String {
+        "\(featuredSource.rawValue)|\(selectedCategory)|\(query)"
     }
 
     var body: some View {
@@ -379,57 +460,12 @@ struct FeaturedView: View {
             ZStack {
                 GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                 VStack(alignment: .leading, spacing: 0) {
-                    HStack(alignment: .center) {
-                        Text("精选")
-                            .font(ATMusicFont.appFont(34, .bold))
-                            .foregroundStyle(Color.atmusicLabel)
-                        Spacer(minLength: 0)
-                        Button(action: onOpenProfile) {
-                            Image(systemName: "person.crop.circle.fill")
-                                .font(.system(size: 24))
-                                .foregroundStyle(Color.atmusicComment.opacity(0.72))
-                                .frame(width: 36, height: 36)
-                                .background { ATMusicGlass(shape: Circle()) }
-                                .clipShape(Circle())
-                        }
-                        .buttonStyle(.plain)
-                        .accessibilityLabel("我的")
-                    }
-                    .padding(.horizontal, 24)
-                    .padding(.top, 10)
-                    .padding(.bottom, 14)
-
+                    header
                     featuredSearchField
                         .padding(.horizontal, 24)
                         .padding(.bottom, 14)
-
-                    ScrollView(.horizontal, showsIndicators: false) {
-                        HStack(spacing: 10) {
-                            ForEach(categories, id: \.self) { category in
-                                Button {
-                                    guard selectedCategory != category else { return }
-                                    ATMusicHaptics.select()
-                                    selectedCategory = category
-                                } label: {
-                                    Text(category)
-                                        .font(ATMusicFont.appFont(13, .medium))
-                                        .atmusicSelectionForeground(selected: selectedCategory == category, accent: .atmusicAmber)
-                                        .padding(.horizontal, 15)
-                                        .padding(.vertical, 8)
-                                        .background {
-                                            ATMusicSelectableSurface(
-                                                selected: selectedCategory == category,
-                                                shape: Capsule(),
-                                                accent: .atmusicAmber
-                                            )
-                                        }
-                                }
-                                .buttonStyle(.plain)
-                            }
-                        }
-                        .padding(.horizontal, 24)
-                    }
-                    .padding(.bottom, 12)
+                    categoryChips
+                        .padding(.bottom, 12)
 
                     ScrollView {
                         if isLoading && playlists.isEmpty {
@@ -438,49 +474,13 @@ struct FeaturedView: View {
                         } else if let errorMessage, playlists.isEmpty {
                             ErrorStateView(message: errorMessage) { Task { await load(reset: true) } }
                                 .frame(maxWidth: .infinity, minHeight: 260)
-                        } else if visiblePlaylists.isEmpty {
+                        } else if playlists.isEmpty {
                             Text("暂无匹配歌单")
                                 .font(ATMusicFont.appFont(14))
                                 .foregroundStyle(Color.atmusicComment)
                                 .frame(maxWidth: .infinity, minHeight: 260)
                         } else {
-                            LazyVGrid(
-                                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
-                                spacing: 18
-                            ) {
-                                ForEach(visiblePlaylists) { playlist in
-                                    NavigationLink {
-                                        PlaylistView(playlist: playlist)
-                                            .environmentObject(auth)
-                                            .environmentObject(player)
-                                    } label: {
-                                        VStack(alignment: .leading, spacing: 7) {
-                                            CoverImage(url: playlist.coverURL, size: 170, cornerRadius: 14)
-                                                .frame(maxWidth: .infinity)
-                                            Text(playlist.name)
-                                                .font(ATMusicFont.appFont(13, .medium))
-                                                .foregroundStyle(Color.atmusicLabel)
-                                                .lineLimit(2)
-                                                .multilineTextAlignment(.leading)
-                                            Text(playlist.trackCount > 0 ? atmusicSongCountText(playlist.trackCount) : "网易云音乐精选")
-                                                .font(ATMusicFont.appFont(11))
-                                                .foregroundStyle(Color.atmusicComment)
-                                                .lineLimit(1)
-                                        }
-                                        .padding(8)
-                                        .background {
-                                            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
-                                        }
-                                    }
-                                    .buttonStyle(.plain)
-                                    .onAppear {
-                                        guard playlist.id == visiblePlaylists.last?.id else { return }
-                                        Task { await loadMoreIfNeeded() }
-                                    }
-                                }
-                            }
-                            .padding(.horizontal, 24)
-                            .padding(.bottom, 190)
+                            playlistGrid
                             if isLoadingMore {
                                 ProgressView()
                                     .frame(maxWidth: .infinity)
@@ -489,15 +489,29 @@ struct FeaturedView: View {
                         }
                     }
                     .atmusicScrollIndicatorsHidden()
-                        .refreshable { await load(reset: true) }
+                    .refreshable { await load(reset: true) }
+                }
+            }
+            .onAppear {
+                categories = FeaturedSource.defaultCategories(for: featuredSource)
+            }
+            .onChange(of: featuredSource) { _, newValue in
+                selectedCategory = "全部"
+                query = ""
+                categories = FeaturedSource.defaultCategories(for: newValue)
+                playlists = []
+                isLoading = true
+                errorMessage = nil
+                if newValue == .netease {
+                    Task { await enrichCategoriesFromNetEase() }
                 }
             }
             .task {
-                await loadCategories()
-                await load(reset: true)
+                if featuredSource == .netease {
+                    await enrichCategoriesFromNetEase()
+                }
             }
-            .task(id: "\(selectedCategory)|\(query)") {
-                guard didLoadCategories else { return }
+            .task(id: reloadTaskID) {
                 if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                     try? await Task.sleep(nanoseconds: 350_000_000)
                     guard !Task.isCancelled else { return }
@@ -507,6 +521,60 @@ struct FeaturedView: View {
         }
     }
 
+    /// 左上角：当前来源品牌图标 + 标题 + 下拉箭头，点击弹出「聚合 / 网易云 / QQ / 酷狗」切换菜单。
+    private var header: some View {
+        HStack(alignment: .center) {
+            Menu {
+                ForEach(FeaturedSource.allCases) { source in
+                    Button {
+                        guard source != featuredSource else { return }
+                        ATMusicHaptics.select()
+                        featuredSourceRaw = source.rawValue
+                    } label: {
+                        Label(source.title, systemImage: source == featuredSource ? "checkmark" : source.menuIcon)
+                    }
+                }
+            } label: {
+                HStack(alignment: .firstTextBaseline, spacing: 8) {
+                    if let imageName = featuredSource.brandImageName {
+                        Image(imageName)
+                            .resizable()
+                            .scaledToFit()
+                            .frame(width: 24, height: 24)
+                    } else {
+                        Image(systemName: featuredSource.aggregateIcon)
+                            .font(.system(size: 20, weight: .semibold))
+                            .foregroundStyle(Color.atmusicAmber)
+                    }
+                    Text(featuredSource.title)
+                        .font(ATMusicFont.appFont(30, .bold))
+                        .foregroundStyle(Color.atmusicLabel)
+                    Image(systemName: "chevron.down")
+                        .font(.system(size: 13, weight: .bold))
+                        .foregroundStyle(Color.atmusicComment)
+                }
+                .contentShape(Rectangle())
+            }
+            .menuStyle(.borderlessButton)
+            .accessibilityLabel("切换精选平台")
+
+            Spacer(minLength: 0)
+            Button(action: onOpenProfile) {
+                Image(systemName: "person.crop.circle.fill")
+                    .font(.system(size: 24))
+                    .foregroundStyle(Color.atmusicComment.opacity(0.72))
+                    .frame(width: 36, height: 36)
+                    .background { ATMusicGlass(shape: Circle()) }
+                    .clipShape(Circle())
+            }
+            .buttonStyle(.plain)
+            .accessibilityLabel("我的")
+        }
+        .padding(.horizontal, 24)
+        .padding(.top, 10)
+        .padding(.bottom, 14)
+    }
+
     private var featuredSearchField: some View {
         HStack(spacing: 9) {
             Image(systemName: "magnifyingglass")
@@ -523,6 +591,92 @@ struct FeaturedView: View {
         }
     }
 
+    private var categoryChips: some View {
+        ScrollView(.horizontal, showsIndicators: false) {
+            HStack(spacing: 10) {
+                ForEach(categories, id: \.self) { category in
+                    Button {
+                        guard selectedCategory != category else { return }
+                        ATMusicHaptics.select()
+                        selectedCategory = category
+                    } label: {
+                        Text(category)
+                            .font(ATMusicFont.appFont(13, .medium))
+                            .atmusicSelectionForeground(selected: selectedCategory == category, accent: .atmusicAmber)
+                            .padding(.horizontal, 15)
+                            .padding(.vertical, 8)
+                            .background {
+                                ATMusicSelectableSurface(
+                                    selected: selectedCategory == category,
+                                    shape: Capsule(),
+                                    accent: .atmusicAmber
+                                )
+                            }
+                    }
+                    .buttonStyle(.plain)
+                }
+            }
+            .padding(.horizontal, 24)
+        }
+    }
+
+    private var playlistGrid: some View {
+        LazyVGrid(
+            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
+            spacing: 18
+        ) {
+            ForEach(playlists, id: \.identityKey) { playlist in
+                NavigationLink {
+                    PlaylistView(playlist: playlist)
+                        .environmentObject(auth)
+                        .environmentObject(player)
+                } label: {
+                    VStack(alignment: .leading, spacing: 7) {
+                        CoverImage(url: playlist.coverURL, size: 170, cornerRadius: 14)
+                            .frame(maxWidth: .infinity)
+                        HStack(spacing: 5) {
+                            Text(playlist.name)
+                                .font(ATMusicFont.appFont(13, .medium))
+                                .foregroundStyle(Color.atmusicLabel)
+                                .lineLimit(2)
+                                .multilineTextAlignment(.leading)
+                            if isAggregate {
+                                SourceBadgeView(source: playlist.source, compact: true)
+                            }
+                        }
+                        Text(playlistSubtitle(playlist))
+                            .font(ATMusicFont.appFont(11))
+                            .foregroundStyle(Color.atmusicComment)
+                            .lineLimit(1)
+                    }
+                    .padding(8)
+                    .background {
+                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
+                    }
+                }
+                .buttonStyle(.plain)
+                .onAppear {
+                    guard playlist.identityKey == playlists.last?.identityKey else { return }
+                    Task { await loadMoreIfNeeded() }
+                }
+            }
+        }
+        .padding(.horizontal, 24)
+        .padding(.bottom, 190)
+    }
+
+    private func playlistSubtitle(_ playlist: Playlist) -> String {
+        if playlist.trackCount > 0 {
+            return atmusicSongCountText(playlist.trackCount)
+        }
+        switch featuredSource {
+        case .aggregate: return playlist.source.atmusicDisplayName
+        case .netease: return "网易云音乐精选"
+        case .qq: return "QQ音乐精选"
+        case .kugou: return "酷狗音乐精选"
+        }
+    }
+
     private func load(reset: Bool) async {
         if reset {
             isLoading = true
@@ -538,17 +692,15 @@ struct FeaturedView: View {
         do {
             let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
             let loaded: [Playlist]
-            if !keyword.isEmpty {
-                loaded = try await NetEaseAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)
-            } else {
-                switch selectedCategory {
-                case "精品歌单":
-                    loaded = try await NetEaseAPI.shared.highQualityPlaylists(cat: "全部", limit: pageSize, offset: nextOffset)
-                case "全部", "推荐歌单":
-                    loaded = try await NetEaseAPI.shared.playlistSquare(cat: "全部", order: "hot", limit: pageSize, offset: nextOffset)
-                default:
-                    loaded = try await NetEaseAPI.shared.playlistSquare(cat: selectedCategory, order: "hot", limit: pageSize, offset: nextOffset)
-                }
+            switch featuredSource {
+            case .netease:
+                loaded = try await loadNetEase(keyword: keyword)
+            case .qq:
+                loaded = try await loadQQ(keyword: keyword)
+            case .kugou:
+                loaded = try await loadKugou(keyword: keyword)
+            case .aggregate:
+                loaded = try await loadAggregate(keyword: keyword)
             }
             guard !Task.isCancelled else { return }
             let countBeforeMerge = playlists.count
@@ -557,15 +709,20 @@ struct FeaturedView: View {
                 seen.insert("\($0.source.rawValue)|\($0.id)").inserted
             })
             nextOffset += loaded.count
-            // 不用“本页少于 pageSize”判断结束：部分网易云接口会强制把单页截成 20 条，
-            // 只要本页还有新歌单就继续翻页，直到空页或接口重复返回同一页。
+            // 网易 / QQ / 酷狗搜索与分类、酷狗歌单广场均支持 offset 分页；
+            // QQ 热门歌单（官网推荐位）一次取完，返回空页或重复页即停止翻页。
             hasMorePlaylists = !loaded.isEmpty && playlists.count > countBeforeMerge
             isLoading = false
             isLoadingMore = false
         } catch {
             isLoading = false
             isLoadingMore = false
-            errorMessage = error.localizedDescription
+            if reset {
+                errorMessage = error.localizedDescription
+            } else {
+                // 翻页失败：静默停止翻页，保留已加载内容，不打断滚动体验
+                hasMorePlaylists = false
+            }
         }
     }
 
@@ -573,27 +730,102 @@ struct FeaturedView: View {
         await load(reset: false)
     }
 
-    private func loadCategories() async {
+    private func loadNetEase(keyword: String) async throws -> [Playlist] {
+        if !keyword.isEmpty {
+            return try await NetEaseAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)
+        }
+        switch selectedCategory {
+        case "精品歌单":
+            return try await NetEaseAPI.shared.highQualityPlaylists(cat: "全部", limit: pageSize, offset: nextOffset)
+        case "全部", "推荐歌单":
+            return try await NetEaseAPI.shared.playlistSquare(cat: "全部", order: "hot", limit: pageSize, offset: nextOffset)
+        default:
+            return try await NetEaseAPI.shared.playlistSquare(cat: selectedCategory, order: "hot", limit: pageSize, offset: nextOffset)
+        }
+    }
+
+    private func loadQQ(keyword: String) async throws -> [Playlist] {
+        if !keyword.isEmpty {
+            return try await QQMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)
+        }
+        switch selectedCategory {
+        case "精品歌单":
+            return try await QQMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)
+        case "全部", "推荐歌单":
+            return try await QQMusicAPI.shared.allPlaylists(limit: pageSize, offset: nextOffset)
+        default:
+            return try await QQMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)
+        }
+    }
+
+    private func loadKugou(keyword: String) async throws -> [Playlist] {
+        if !keyword.isEmpty {
+            return try await KugouMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)
+        }
+        switch selectedCategory {
+        case "精品歌单":
+            return try await KugouMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)
+        case "全部", "推荐歌单":
+            return try await KugouMusicAPI.shared.recommendPlaylists(limit: pageSize, offset: nextOffset)
+        default:
+            return try await KugouMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)
+        }
+    }
+
+    /// 聚合：三平台并行拉取后合并，单卡附带平台徽标。
+    private func loadAggregate(keyword: String) async throws -> [Playlist] {
+        if !keyword.isEmpty {
+            async let netease: [Playlist] = (try? await NetEaseAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)) ?? []
+            async let qq: [Playlist] = (try? await QQMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)) ?? []
+            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)) ?? []
+            let (n, q, k) = try await (netease, qq, kugou)
+            return interleave(n, q, k)
+        }
+        switch selectedCategory {
+        case "精品歌单":
+            async let netease: [Playlist] = (try? await NetEaseAPI.shared.highQualityPlaylists(cat: "全部", limit: pageSize, offset: nextOffset)) ?? []
+            async let qq: [Playlist] = (try? await QQMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)) ?? []
+            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)) ?? []
+            let (n, q, k) = try await (netease, qq, kugou)
+            return interleave(n, q, k)
+        case "全部", "推荐歌单":
+            async let netease: [Playlist] = (try? await NetEaseAPI.shared.playlistSquare(cat: "全部", order: "hot", limit: pageSize, offset: nextOffset)) ?? []
+            async let qq: [Playlist] = (try? await QQMusicAPI.shared.allPlaylists(limit: pageSize, offset: nextOffset)) ?? []
+            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.recommendPlaylists(limit: pageSize, offset: nextOffset)) ?? []
+            let (n, q, k) = try await (netease, qq, kugou)
+            return interleave(n, q, k)
+        default:
+            async let netease: [Playlist] = (try? await NetEaseAPI.shared.playlistSquare(cat: selectedCategory, order: "hot", limit: pageSize, offset: nextOffset)) ?? []
+            async let qq: [Playlist] = (try? await QQMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)) ?? []
+            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)) ?? []
+            let (n, q, k) = try await (netease, qq, kugou)
+            return interleave(n, q, k)
+        }
+    }
+
+    /// 聚合歌单各平台交叉轮流显示：网易 → QQ → 酷狗 → 网易 → …
+    private func interleave(_ arrays: [Playlist]...) -> [Playlist] {
+        var result: [Playlist] = []
+        let maxCount = arrays.map(\.count).max() ?? 0
+        for i in 0..<maxCount {
+            for arr in arrays where i < arr.count {
+                result.append(arr[i])
+            }
+        }
+        return result
+    }
+    /// 网易云来源远程分类丰富：接口正常时使用服务端全部分类；失败时保留通用分类兜底。
+    private func enrichCategoriesFromNetEase() async {
+        guard featuredSource == .netease else { return }
         let remote = await NetEaseAPI.shared.playlistCatlist()
         guard !Task.isCancelled else { return }
-
-        // 接口正常时使用服务端全部分类；网络或上游结构异常时也保留完整的本地分类兜底，
-        // 避免页面退化成只有“全部 / 推荐 / 精品”三个入口。
-        let fallback = [
-            "华语", "欧美", "日语", "韩语", "粤语", "小语种",
-            "流行", "摇滚", "民谣", "电子", "舞曲", "说唱", "轻音乐", "爵士", "乡村", "古典", "民族", "英伦", "金属", "朋克", "蓝调", "雷鬼", "拉丁", "另类/独立", "世界音乐", "New Age", "古风", "BGM", "嘻哈", "网络歌曲", "DJ", "R&B/Soul",
-            "清晨", "夜晚", "学习", "工作", "午休", "下午茶", "地铁", "驾车", "运动", "旅行", "散步", "酒吧",
-            "怀旧", "清新", "浪漫", "性感", "伤感", "治愈", "放松", "孤独", "感动", "兴奋", "快乐", "安静", "思念",
-            "综艺", "影视原声", "ACG", "儿童", "校园", "游戏", "翻唱", "器乐", "亲子", "公益", "乡村", "婚礼", "派对", "音乐播客"
-        ]
-        var merged: [String] = []
-        for category in ["全部", "推荐歌单", "精品歌单"] + remote + fallback {
-            let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
-            guard !name.isEmpty, !merged.contains(name) else { continue }
-            merged.append(name)
+        var merged: [String] = ["全部", "推荐歌单", "精品歌单"]
+        for name in remote + FeaturedSource.commonCategories {
+            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
+            guard !trimmed.isEmpty, !merged.contains(trimmed) else { continue }
+            merged.append(trimmed)
         }
         categories = merged
-        didLoadCategories = true
     }
 }
 
diff --git a/ATMusic/SectionOrderStore.swift b/ATMusic/SectionOrderStore.swift
index 73bcca2..5b243b7 100644
--- a/ATMusic/SectionOrderStore.swift
+++ b/ATMusic/SectionOrderStore.swift
@@ -10,7 +10,7 @@ enum SectionOrderStore {
     /// 音乐库板块默认顺序
     static let libraryDefaults = ["我的歌单", "最近播放", "本地音乐库"]
     /// 主页板块默认顺序
-    static let homeDefaults = ["每日推荐", "歌单广场", "排行榜"]
+    static let homeDefaults = ["每日推荐", "最近播放", "排行榜"]
     /// 我的界面板块默认顺序
     static let profileDefaults = ["账号", "关于"]
 
diff --git a/CHANGELOG.md b/CHANGELOG.md
index f8a41d9..acbeac2 100644
--- a/CHANGELOG.md
+++ b/CHANGELOG.md
@@ -1,5 +1,55 @@
 # AT Music 更新日志
 
+## 1.8.9 build 47
+
+### 精选页 QQ / 酷狗无限下拉修复
+- QQ 歌单搜索改用 client_search_cp 稳定接口（与歌曲/专辑搜索同源，不受 musicu 风控影响），精选页 QQ 歌单可稳定无限翻页。
+- 精选页翻页失败改为静默停止（保留已加载内容），不再弹出“断网”提示；仅首屏加载失败才显示错误。
+
+### 主页每日推荐卡片
+- QQ 主页“每日推荐”卡片由正方形改为 2:1 长方形。
+
+### 歌词与聚合
+- 歌词行距滑杆范围扩大到 4~40（可继续调小），默认行距调整为更紧凑的 16pt。
+- 聚合页推荐栏在启用酷狗时也展示“酷狗私人漫游”（不再因同时启用网易而隐藏）。
+
+## 1.8.9 build 46
+
+### 精选页歌单无限下拉
+- QQ 音乐“全部 / 推荐歌单”分类改用可分页的歌单广场接口（音乐馆 GetPlayList），并带热门歌单 / 搜索分页兜底，可像网易一样一直下拉。
+- 酷狗“全部 / 推荐歌单”分类翻页改用移动站歌单广场分页兜底，可一直下拉。
+- 聚合页三平台同步分页，各平台持续交叉加载。
+
+### 聚合页歌单交叉显示
+- 聚合页歌单改为各平台交叉轮流排列：网易 → QQ → 酷狗 → 网易 → …，不再按平台整块堆叠。
+
+### 首页推荐栏增强
+- QQ 每日推荐栏增加个人红心歌曲（“我喜欢”），与每日推荐合并去重。
+- 酷狗每日推荐栏增加私人 FM 歌曲，与每日推荐合并去重。
+
+## 1.8.9 build 45
+
+### 精选页多平台歌单分页
+- QQ 音乐歌单搜索与分类筛选支持翻页加载，滚动到底继续获取下一批。
+- 酷狗音乐歌单广场、歌单搜索与分类筛选支持翻页加载，滚动到底继续获取下一批。
+- 聚合页三平台歌单同步支持分页，各平台按 offset 渐进加载合并去重。
+
+### 主页最近播放
+- 主页原“歌单广场”栏改为“最近播放歌曲”，展示方式保持方块横滑卡片不变。
+- 单平台主页只显示该平台的最近播放；聚合主页按播放顺序展示所有平台的最近播放。
+- 点击最近播放卡片即可从该位置开始播放。
+
+## 1.8.9 build 44
+
+### 精选页多平台歌单
+- 精选页左上角新增来源切换菜单（与主页左上角一致的交互方式），可在「聚合 / 网易云 / QQ / 酷狗」四种歌单之间切换。
+- 新增 QQ 音乐歌单页：默认展示 QQ 热门歌单，支持歌单搜索与分类筛选。
+- 新增酷狗音乐歌单页：默认展示酷狗歌单广场，支持歌单搜索与分类筛选。
+- 新增聚合歌单页：三平台歌单并行加载合并展示，每张卡片带平台徽标。
+- 网易云歌单页保持原有分类、搜索与分页加载能力不变。
+- 所有来源沿用精选页统一的双列歌单网格、搜索框、分类胶囊与下拉刷新，UI 完全对齐系统原生风格。
+- 记住用户上次选择的来源，下次打开精选页沿用。
+
 ## 1.8.9 build 43
 
 ### 歌词展示页
diff --git a/project.yml b/project.yml
index eeacb2b..b9f4bf7 100644
--- a/project.yml
+++ b/project.yml
@@ -20,7 +20,7 @@ targets:
       base:
         PRODUCT_BUNDLE_IDENTIFIER: com.atmusic.player
         MARKETING_VERSION: "1.8.9"
-        CURRENT_PROJECT_VERSION: "43"
+        CURRENT_PROJECT_VERSION: "47"
         TARGETED_DEVICE_FAMILY: "1,2"
         SWIFT_OBJC_BRIDGING_HEADER: ATMusic/ATMusic-Bridging-Header.h
         ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon


---

*本文档由迭代记录整理生成，可直接提供给后续大模型作为改动依据。*
