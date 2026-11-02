# AT Music 当前交接文档

更新时间：2026-09-25  
代码目录：`/Users/tangfengjing/gemini/app_music/AT-Music-main`  
当前版本：`1.8.1 (build 32)`  
真机状态：Build 32 已安装到 iPhone Tang；Release 真机构建、严格签名校验、覆盖安装与远程启动均成功，启动后进程持续存活。

## 当前目标与界面基线

- **界面基线**：AT Music 1.8.1。开发版保留 NAS、本地音乐与聚合首页等扩展能力，但常用页面层级、列表密度、设置入口和播放器设置以 1.8.1 为准。
- **聚合首页保留**：不应因对照 1.8.1 而移除。首页支持聚合与单平台模式。
- **安全要求**：NAS 地址、密码、会话 `_sid`、第三方 Cookie/Token 仅可存入 Keychain 或用户设备，不写入文档、日志、提交记录或源码。

## 已完成

### 聚合、搜索与平台

- 已接入网易云、QQ、酷狗、NAS；汽水音乐平台及其搜索、播放、歌单、收藏、下载、配置与登录代码已于 2026-09-25 移除。
- 聚合搜索支持歌曲、歌手、专辑、歌单分区，结果携带来源标识，可多选平台范围。
- 聚合首页保留；歌单按平台分组。每个平台标题最右侧有展开箭头：
  - 收起：横向首屏预览；
  - 展开：在当前页显示该平台全部歌单，双列卡片；
  - 再点箭头：恢复横向预览。
- 聚合歌单逻辑位置：`ATMusic/DiscoverView.swift`，`aggregatePersonalizedSection`。

### 所有连续歌曲列表统一样式

- 歌单、专辑、歌手歌曲、搜索、本地音乐、NAS、NAS 文件夹目录、历史和播放队列统一为 1.8.1 连续紧凑行：
  - 46pt 封面；
  - 64pt 最小行高；
  - 行内细分隔线；
  - 取消逐首玻璃卡片。
- 通用组件：`ATMusic/SongCell.swift`。
- 歌单专用行：`ATMusic/PlaylistView.swift` 的 `PlaylistTrackRow`。
- 队列专用行：`ATMusic/QueueView.swift`。
- NAS 文件夹/歌单/歌手目录行：`ATMusic/SynologyMusicView.swift` 的 `SynologyLibraryRow`。

### NAS 音乐与元数据编辑

- NAS 支持曲库、文件夹、歌手、专辑、歌单、搜索与播放。
- NAS 歌曲信息编辑为半屏信息卡，点击单字段才进入全屏编辑；标签可独立修改，未修改字段必须保留原值。
- 封面搜索支持网易云、QQ、酷狗候选和本机选图。
- 已修复此前保存长时间等待后失败的主要问题：
  - Audio Station 的 `tag_editor.cgi` 需要与网页编辑器一致的完整 `audioInfos`/标签/封面字段结构；旧代码仅提交 patch，服务端会判为无效。
  - 保存前会读取 NAS 原始标签，再只合并用户改动。
  - 在线封面改为 NAS 直接获取；本机选图先压缩到合理尺寸后上传。
  - 对权限不足、磁盘只读、文件移动等失败给出具体错误。
- 主要实现：`ATMusic/SynologyAPI.swift` 的 `applyMetadata`、`tagEditorPayload`、`validateTagEditorWrite`、`optimizedCoverData`；界面：`ATMusic/SynologyMusicView.swift`。
- 2026-09-23 二次修复 NAS 标签“提示成功但实际不变”：`tag_editor.cgi` 的 `apply` 请求中，`audioInfos` 不能只有 `path`，必须携带 `load` 返回的修改前完整标签快照；外层字段才是要写入的新值。现在保存后还会再次 `load` 回读核对用户修改字段，只有确认实际变化才提示成功；NAS 曲库页也会在 `libraryIndexRevision` 变化后自动刷新。
- 2026-09-23 build 17 修正 `tag_editor.cgi` 的读取参数：`action=load` 必须提交表单字段 `audioInfos=[{"path":"..."}]`，不能使用 `data`；`action=apply` 才使用 `data=[{...}]`。build 16 因误把 load 也提交为 `data`，导致 NAS 返回中没有 `files`，界面提示“没有返回原歌曲标签”。
- **仍需真机重点验证**：仅改一个标签、只改在线封面、选择本机图片；如有失败，请记录页面提示的具体错误文本和歌曲所在 NAS 路径类型。

### 播放器

- 提供经典、Apple Music、唱片三种样式，以及布局编辑器和按设备比例的播放页预览。
- 封面播放页：歌曲名/副标题居中，不显示红心和更多菜单。
- 歌词页：右上角保留红心和更多菜单；更多菜单包含定时关闭、歌曲信息、添加到歌单、下载（若可用）、NAS 编辑入口和播放器设置。
- 三种样式均已对应：
  - Apple Music 参考播放器：`ATMusic/ReferencePlaybackView.swift`；
  - 经典/唱片播放器：`ATMusic/PlayerView.swift`。
- 播放页下方维持歌词、评论、播放队列三个主入口。

### 设置与主题

- 主题模式：浅色、深色、跟随系统。
- 已有“关闭液态效果”，影响液态玻璃与动态背景。
- 已统一一批通用强调色（设置、底栏、搜索、首页公告、个人页、布局编辑器）。
- 1.8.1 设置逐项对照清单：`docs/1.8.1-设置逐级对照清单.md`。其中仍标记 🟡 的项目需要按“原版截图/操作 → 开发版比对 → 真机实际操作 → 返回和重开验证”完成，不应只凭编译通过标记完成。

## 最近改动顺序

1. **build 32 (2026-09-25)**：完成搜索稳定性、歌词定位、QQ 首页歌单数量及 iOS 27 原生 UI/导航一轮总修复。
   - 搜索：IME marked text 组字期间禁止 SwiftUI 反写 UITextField；热搜/历史/回车跳过 debounce；输入新词立即使旧请求失效；平台范围/NAS 刷新合并；旧请求不能覆盖新结果。
   - QQ 首页歌单：不再把 `listennum` 当歌曲数；热门歌单逐 ID 并发详情请求获取真实 `songnum/songlist.count`。
   - 歌词：主歌词、Apple Music/参考歌词、唱片歌词使用稳定行槽位，翻译/时间显隐不再改变滚动目标 geometry，修复高亮位置逐渐下移。
   - iOS 27：Root 使用系统 TabView/Search role/tabViewBottomAccessory/tabBarMinimizeBehavior；清理旧自绘底栏和滚动探针。
   - 三种播放器布局编辑器使用真实 PlayerView 预览；经典/Apple Music/唱片分别独立布局；唱片基础结构与五键控制按参考图校正。
   - Release `BUILD SUCCEEDED`，严格 codesign 通过，Build 32 已覆盖安装并成功启动于 iPhone Tang。
1. **build 32（2026-09-25）**：完成 iOS 27 原生 UI/动画、搜索稳定性、三套播放器布局与歌词锚点修复。
   - RootView 改为系统 TabView + Search role + tabBarMinimizeBehavior + tabViewBottomAccessory；移除旧自绘底栏、滚动探针和自定义收缩状态。
   - 搜索统一请求管线：输入 debounce、立即搜索、平台范围合并、NAS 延迟刷新、generation 防迟到回包、中文 IME marked text 保护，避免重复请求和闪屏。
   - 播放器布局编辑器使用真实 PlayerView 真机比例预览；经典 / Apple Music / 唱片三套布局独立持久化并按参考图建立基线。
   - 唱片模式调整为唱盘居中 + 下方歌曲信息 + 五键控制；随机播放真实重排可见 queue。
   - 聚合歌单页包含最近播放 / 我的歌单 / 本地音乐库，并支持模块排序；各平台歌单分块展示。
   - Apple Music 歌词修复高亮位置下漂：高亮前后行布局尺寸固定，翻译/时间保留占位，视口留白直接使用 GeometryReader，取消二次布局。
   - Release Build 32 构建、严格 codesign 校验、覆盖安装、远程启动均成功；真机进程保持运行。
1. **build 31（2026-09-25）**：完成本轮最终修复与真机安装。
   - 搜索状态机进一步稳定：清空输入会取消旧请求；热搜/历史/回车不再重复触发 debounce；新关键词立即使旧 generation 失效；平台/聚合范围切换合并为单次刷新；NAS 延迟补搜校验当前关键词；中文输入法 marked text 期间不发请求；聚合结果保留旧快照直到新快照原子替换，避免闪空。
   - RootView 现代路径只保留系统 `TabView` / `Tab(role: .search)` / `tabBarMinimizeBehavior(.onScrollDown)` / `tabViewBottomAccessory`；旧自绘底栏、滚动探针和自定义收缩状态已删除。
   - 三套播放器布局继续按参考图校准：经典封面默认 X=0/Y=0/大小=1.00；Apple Music 使用独立布局存储；唱片模式默认唱片 X=0/Y=20/大小=1.00，并改为唱盘居中、歌名/歌手位于唱盘下方、五键底部控制。
   - 四种全局 UI 样式统一走 `ATMusicGlass` / `ATMusicSurface` / `ATMusicLiquidSelectionSurface`，业务页面不再硬编码 `forceLiquid: true`。
   - Release Build 31 无编译 warning，`codesign --verify --deep --strict` 通过，已覆盖安装并成功启动于 iPhone Tang。
   - `install_at_music.sh` 更新为安全事务式流程：独立临时构建目录；Build 号通过 xcodebuild 临时覆盖；构建/验签/安装全部成功后才写回工程 Build 号；失败不会污染工程版本，也不会复用旧残缺 `.app`。
1. **build 29（2026-09-25）**：完成 iOS 27 原生交互、三套播放器布局、聚合歌单和安装流程的最终回归。
   - iOS 26/27 根导航改为系统 `TabView`；搜索使用 `Tab(role: .search)`，滚动收缩使用 `tabBarMinimizeBehavior(.onScrollDown)`，MiniPlayer 使用 `tabViewBottomAccessory`，两层/一层切换由系统原生动画负责。
   - 默认液态 / 磨砂玻璃 / 紧凑淡雅 / Apple 简洁四种全局 UI 样式统一驱动 `ATMusicGlass`、选中态、播放器按钮、队列、歌单和系统 Tab 背景；关闭液态玻璃时选中态也同步降级。
   - 全项目已清除手写 `.spring/.ease/.timingCurve` UI 曲线；现代歌词页统一使用 `scrollPosition + scrollTargetLayout + onScrollPhaseChange`，旧 `ScrollViewReader` 只保留给低系统版本 fallback。
   - 布局编辑器中间预览为真实 `PlayerView` 的 iPhone 比例真机预览，三套风格各自独立存储；V6 首次迁移按参考图恢复经典 / Apple Music / 唱片模式基线。
   - 随机播放会真实重排可见 `queue`，当前歌曲保持播放；歌单页聚合最近播放 / 多平台我的歌单 / 本地音乐库，并沿用页面排序和平台排序。
   - Build 29 已确认 `codesign --verify --deep --strict` 通过；真机安装版本为 1.8.1 (29)，远程启动成功且对应进程持续存活。
   - `install_at_music.sh` / `一键安装AT Music.command` 增加单实例锁；重复双击会拒绝第二个任务，避免并发构建互相覆盖临时构建目录。
1. **build 26 (2026-09-25)**: completed the player-layout, global-UI, shuffle-queue and aggregated-playlist structural fixes.
   - Classic / Apple Music / Vinyl layouts are independent; Classic and Vinyl no longer share the same layout data.
   - Layout preview now renders the real `PlayerView`; editor changes are broadcast live to the preview.
   - `atmusic.uiStyle` is authoritative for global surfaces: Liquid / Frosted / Compact / Apple Clean now drive dock, shared buttons, player controls, queue mode cards and key overlays consistently.
   - Shuffle now visibly reorders `queue` while keeping the current song playing; the queue screen shows the actual upcoming order immediately.
   - Playlist page is aggregated into sortable Recent / My Playlists / Local Library modules; My Playlists is grouped by enabled platform and follows platform ordering.
   - Build 26 Release build succeeded, strict codesign verification passed, and the app was installed and launched on iPhone Tang.
2. build 13：聚合歌单改为完整入口；歌单详情歌曲列表改为连续紧凑行。
3. build 14：所有连续歌曲列表与 NAS 目录统一为 1.8.1 紧凑行；封面播放页标题居中、移除标题行操作按钮。
4. build 15：纠正播放器逻辑——仅封面播放页隐藏红心/更多；歌词页右上角恢复红心与扩展菜单。

## 本地构建与真机安装

### 无签名编译校验

```bash
xcodebuild -project ATMusic.xcodeproj -scheme ATMusic \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/atmusic-build-verify \
  CODE_SIGNING_ALLOWED=NO build
```

### 真机构建

签名身份、描述文件和设备标识均为本机私密配置，**不要写入仓库或本文档**。使用团队已有的 Release 手工签名配置构建，随后执行：

```bash
codesign --verify --deep --strict --verbose=2 /path/to/ATMusic.app
xcrun devicectl device install app --device <device-id> /path/to/ATMusic.app
```

每次安装前递增 `CURRENT_PROJECT_VERSION`，同时更新：

- `project.yml`
- `ATMusic.xcodeproj/project.pbxproj`

当前值为 `26`。

## 关键文件导航

| 领域 | 主要文件 |
| --- | --- |
| 首页/聚合歌单/排行榜 | `ATMusic/DiscoverView.swift` |
| 聚合搜索 | `ATMusic/SearchView.swift`, `ATMusic/AggregatedSearchService.swift` |
| 播放与歌词 | `ATMusic/PlayerView.swift`, `ATMusic/ReferencePlaybackView.swift`, `ATMusic/PlayerManager.swift` |
| 紧凑歌曲行 | `ATMusic/SongCell.swift`, `ATMusic/PlaylistView.swift`, `ATMusic/QueueView.swift` |
| NAS | `ATMusic/SynologyAPI.swift`, `ATMusic/SynologyMusicView.swift`, `ATMusic/SynologyLoginSheet.swift` |
| 本地音乐 | `ATMusic/LocalMusicSection.swift`, `ATMusic/LocalLibraryStore.swift` |
| 设置/主题 | `ATMusic/ProfileView.swift`, `ATMusic/Theme.swift`, `ATMusic/PlayerLayout.swift` |
| 更新日志 | `ATMusic/Changelog.swift`, `CHANGELOG.md` |

## 后续建议优先级

1. 真机回归 NAS 标签和封面写入：先验证一首可安全修改的测试文件，确认 Audio Station 写回后重启应用仍能读到新标签。
2. 按 `docs/1.8.1-设置逐级对照清单.md` 对设置页逐层做真机核对，不要一次性大改设置架构。
3. 聚合/单平台首页、搜索、歌手和专辑页面继续检查真实数据量和分页；新增平台必须接入统一来源与能力模型，不能为某个平台写死 UI 分支。
4. 再次修改播放器时，分别检查封面页和歌词页、三种播放器样式及布局编辑预览，避免只改一个实现。

## 2026-09-25 / 1.8.3 build 34

- 汽水音乐平台已从活动代码中完整移除：搜索、播放、歌词、歌单、收藏、下载、设置、二维码登录、平台模型与适配器均不再保留。
- 聚合主页首次无缓存加载改为渐进式提交：任一平台先返回有效快照就立即展示，后续平台继续补齐，避免等待最慢平台造成长时间空白。
- 首页左上角平台切换由长按改为直接点击标题/下拉图标。
- 网易云主页第一排为“每日推荐 + 红心雷达”，私人漫游排在其后。

## 2026-09-25 / 1.8.4 build 35

- 主页体系统一：网易 / QQ / 酷狗共用相同推荐卡、平台切换和板块结构；网易特殊 reference 首页已移除。
- 网易第一排为“每日推荐 + 红心雷达”；主页标题和平台胶囊都能直接切换聚合/单平台。
- 首页单平台和聚合均改为渐进加载；DiscoverCache 增加 Library/Caches 磁盘快照，冷启动先展示缓存再静默刷新。
- 默认首页顺序为推荐 → 歌单 → 排行榜；NAS 首页也按相同节奏简化，并先拉 240 首首屏数据、1000 首完整库静默补齐。
- 新增统一 ATMusicSelectableSurface，修复搜索“聚合”、播放全部及同类选择器浅底白字问题。

## 2026-09-25 / 1.8.5 build 36

- 修复播放队列编辑时歌名持续抖动：稳定 Queue 行 identity，编辑态禁用外部隐式动画，当前播放 waveform 改为静态占位。
- GlassButton 统一加入四主题匹配的按压反馈与 haptic；歌单“播放全部 / 随机播放”等动作不再无感。
- `ATMusicSelectableSurface` 和 `atmusicSelectionForeground` 现在都按 liquid / clear / compact / nativeClean 分别决定外观，不再只统一成一套选中态。

## UI 修改全局检查规则（2026-09-25 起强制）

任何看似局部的 UI / 交互修改，都必须同时做以下检查，不能只修当前页面：

1. 四套 UI 风格都要验证：`liquid`（默认液态）、`clear`（磨砂玻璃）、`compact`（紧凑淡雅）、`nativeClean`（Apple 简洁）。
2. 先查是否已有全局组件；选择器优先复用 `ATMusicSelectableSurface` + `atmusicSelectionForeground`，按钮优先复用 `GlassPressButtonStyle` / `GlassButton`。
3. 同语义控件必须全局搜索：例如“播放全部 / 随机播放 / 聚合 / 平台切换 / 编辑 / 选择器”，不能只改用户截图所在页面。
4. 每个可点击主操作至少同时有视觉反馈；设置允许触感时还要有 haptic。
5. 涉及列表、播放状态或频繁 `@Published` 更新时，要检查 SwiftUI 行 identity、隐式动画和动态 symbolEffect，避免抖动/闪屏。
6. 修改完成后至少做：全项目同类模式扫描 + 四 UI 启动验证 + Simulator Debug build；准备交付时再做 iPhoneOS Release 无签名构建。

## 2026-09-25 / 1.8.6 build 37

- 底部 `library` Tab 正式命名为“音乐库”，入口组件改为 `MusicLibraryHomeView`。
- 音乐库首屏固定结构：最近播放 / 本地音乐 / NAS 文件 + 最多 8 个我的歌单；旧 `LibraryView` 只作为二级“歌单管理”保留。
- 新增 `MusicLibraryView.swift`：负责轻量首页、全部歌单筛选、本地音乐浏览、本地文件/专辑/歌手/歌单二级页面以及 NAS 文件入口。
- 本地音乐目前无法恢复导入前的真实目录层级，因为现有导入器会存为 `ATMusicAudio/aud_<UUID>.<ext>`；因此本地浏览按真实数据组织为文件 / 专辑 / 歌手 / 本地歌单，不能伪造文件夹。
- `SynologyFolderView` 继续使用 Audio Station folder API，现支持文件夹优先排序、当前目录搜索、播放全部与随机播放，并保持递归进入子文件夹。
- `PlaylistView` 已瘦身：搜索迁移到 `.searchable`、排序进入 toolbar、简介单行可展开、首屏操作区只保留播放全部 + 随机播放。
- 音乐库多平台歌单刷新为网易 / QQ / 酷狗 / NAS 并发，继续复用 `SyncedPlaylistCache`。

### 1.8.6 最终音乐库实现补充

- 底部 Tab 为“音乐库”，正式入口使用 MusicLibraryHomeView；旧 LibraryView 仅保留为二级“歌单管理”。
- 音乐库首屏固定：最近播放 / 本地音乐 / NAS 文件 + 最多 8 个跨来源歌单预览。
- 本地音乐按真实数据提供“文件 / 专辑 / 歌手 / 本地歌单”；导入文件因内部存储会重命名，不伪造原目录树，文件页通过 LocalAudioFileManager 显示真实 originalFilename。
- NAS 文件使用 SynologyFolderView 递归浏览，增加面包屑与未连接空态；文件夹始终排在歌曲之前。
- 多平台歌单使用缓存先展示 + MainActor 安全的渐进并发刷新，任一来源先返回就先更新。
- 歌单详情首屏进一步瘦身：80pt 封面 + 核心信息 + 播放/随机；搜索按需展开，排序与简介/热度进入右上角更多菜单。

## 2026-09-25 / 1.8.7 build 38

- 歌单管理 Sheet 通过 `LibraryView(showsCloseButton: true)` 提供明确“完成”退出，不依赖下拉手势。
- `MusicLibraryAllPlaylistsView` 增加常驻歌单名搜索；统一排序为本地红心 → 平台红心 → 最近活动；`PlaylistActivityStore` 持久化最近打开时间。
- `MusicLibraryPlaylistRow` 删除手写 chevron，NavigationLink 只显示一个系统箭头。
- 本地歌曲元数据保存改为 `LocalLibraryStore.updateImportedSong -> Bool`，显式持久化并读回核心字段；成功后 `PlayerManager.replaceSong` 同步队列/历史/Now Playing。自定义封面使用新的受管文件 URL，避免旧图片缓存。
- 第三方音源播放开始立即 `refreshPrefetchTarget()`；曲末增加 generation 防重的延迟兜底，解决部分第三方直链不发结束通知导致无法自动下一首。全部重试失败后自动跳歌等待缩短到 2 秒。
- `SynologyFolderView` 改为缓存先展示 + 120 条分页渐进加载；`SynologyAPI` 新增按服务器/目录隔离的持久化文件夹缓存，新鲜 TTL 5 分钟、旧缓存可先展示 24 小时，下拉刷新强制失效当前目录缓存。

## 2026-09-25 / 1.8.8 build 39

- 平台隐藏统一应用到音乐库歌单、首页歌单预览和搜索结果。
- 在线封面搜索显示真实像素分辨率。
- 歌词字号/行距与 PlayerView 共用 AppStorage，设置即时生效。
- 编辑型 Sheet 改为大尺寸原生弹窗并禁用背景交互。
