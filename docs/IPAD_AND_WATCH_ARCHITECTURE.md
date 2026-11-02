# AT Music iPadOS 深度自适应重构与 Apple Watch (iWatch) 协同架构文档

## 1. 架构总览与核心设计原则

为彻底解决在 iPad 运行呈现为“拉伸版 iPhone”的问题，本次重构基于 **iPadOS Apple Music** 原生人机交互规范（Human Interface Guidelines）进行了全局架构升级，达成以下关键目标：

1. **iPhone 界面保持原样**：
   * 采用 `DeviceLayoutHelper.isIPadRegular(horizontalSizeClass)` 进行环境与设备形态二路分流。
   * iPhone 与 iPad 紧凑分屏（Slide Over / 1/3 屏幕）依然 100% 保持原有的 iOS 26+ `TabView`、Liquid Glass 浮动底栏与单栏交互逻辑，完全零回归。
2. **iPad 专属 Apple Music 多栏分栏架构**：
   * 宽屏（Regular）模式自动激活两栏式 `NavigationSplitView` 侧边栏导航体系。
   * 全局卡片、歌单、排行榜、搜索结果与歌曲列表全面采用自适应网格（Adaptive Grid）与双列分流。
   * 歌单详情页重构为 Apple Music 标志性的「左侧固定大封面信息栏 + 右侧双列歌曲流」左右分栏。
   * 播放器重构为 iPad 标志性的「左侧大封面中控台 + 右侧实时同步滚动歌词/待播队列」左右双栏并排。
3. **原生 Apple Music / 系统级模块最大化调用**：
   * 全面集成 `AVRoutePickerView`（AirPlay 隔空播放选择器），在播放器与侧栏直呼系统投音面板。
   * 强化 `MPRemoteCommandCenter` 锁屏与外设控制（新增锁屏红心收藏、±15 秒快进快退、进度定位）。
   * 深度整合 `MPNowPlayingInfoCenter` 与原生后台播放流水线。
4. **新增 Apple Watch (iWatch) 完整界面与双向通信架构**：
   * 构建 `WatchConnectivity` 双向数据通道，实时同步曲目、进度、播放状态与封面。
   * 提供专属 watchOS 界面（支持数码表冠 Digital Crown 旋转调节音量、大按键切歌、红心收藏与队列查看）。

---

## 2. iPad 界面自适应重构细节

### 2.1 全局侧边栏（`IPadRootView.swift`）
* **NavigationSplitView 架构**：
  * 左侧栏宽度可调节（240pt ~ 320pt），归类划分为：
    * **发现**：主页（`RootTab.discover`）、精选（`RootTab.featured`）、搜索（`RootTab.search`）。
    * **资料库**：音乐库（`RootTab.library`）、我的账户（`RootTab.profile`）。
    * **音频输出**：内嵌系统原生 AirPlay 投播组件。
  * **侧栏底置迷你播放器**：大屏下直接固定于侧栏底端，包含曲目封面、歌名歌手、快速播放/暂停与切歌，点击一键展开全屏播放器。

### 2.2 自适应网格与内容宽度（`DeviceLayoutHelper.swift`）
* **解除 860pt 居中锁死限制**：iPad 宽屏下最大可用宽度提升至 `1280pt`，彻底消除 11"/13" iPad 横屏下的两侧大黑边。
* **卡片自适应列数**：
  * 发现页歌单广场（`DiscoverView`）、音乐库（`MusicLibraryView`）、搜索（`SearchView`）中的歌单与专辑网格：
    * iPhone: 保持 2 列。
    * iPad: 动态计算为 `GridItem(.adaptive(minimum: 150, maximum: 240))`，横屏自动展开为 4~6 列。
* **歌单详情页主副分栏（`PlaylistView.swift`）**：
  * 左侧（240pt）：固定 220x220 大封面、歌单名、创建者、播放量、简介及“播放全部 / 随机播放”胶囊按钮。
  * 右侧：双列并排单曲流（`DeviceLayoutHelper.songListColumns`），避免单曲行横跨 1300pt 导致间距失衡。

### 2.3 iPad 专属侧边分栏播放器（`IPadPlayerView.swift`）
* **左栏（42% 宽，最高 500pt）**：
  * 1:1 大尺寸专辑封面，配合播放呼吸缩放动画与深度环境投影。
  * 歌曲标题与歌手名（自适应截断）。
  * 实时进度条（Scrubber）：支持轻点与顺滑拖拽跳转。
  * 核心中控台：随机播放、上一曲、显目圆形播放/暂停大按键、下一曲、循环模式。
  * 系统音量调节条 + 隔空播放（AirPlay）设备切换入口。
* **右栏（58% 宽弹性填充）**：
  * **实时同步滚动歌词**：当前播放行大字号加粗高亮发光并居中，未播行自动虚化渐隐，支持轻点任意一行歌词精准 seek 播放。
  * **待播清单（Queue）**：内联展示后续曲目，轻点直达切歌，并展示当前播放动态声波动画。

---

## 3. Apple Watch (iWatch) 界面与协同架构

### 3.1 目录结构与模块说明
* `ATMusic/WatchSyncService.swift`（iOS 主端）：
  * 管理 `WCSession` 生命周期。
  * 当播放器切歌、暂停、开始播放或更新进度时，自动通过 `updateApplicationContext` 与 `sendMessage` 向手表广播最新播放上下文。
  * 监听手表发来的远程控制指令，分发给 `PlayerManager` 执行。
* `ATMusicWatch/`（watchOS 端专用）：
  * `WatchSessionManager.swift`：手表端状态监听与指令发送中枢。
  * `WatchNowPlayingView.swift`：手表端「正在播放」主界面。
    * 封面缩略图、歌曲名、歌手名。
    * 橙色高亮进度条。
    * 上一曲、大播放/暂停按键、下一曲。
    * **数码表冠交互**：绑定 `.digitalCrownRotation`，旋转表冠即可平滑线性调节 iPhone/iPad 播放音量，带 Apple 触觉震动反馈。
    * 快速红心收藏按钮。
  * `WatchQueueView.swift`：手表端播放队列与快速控制列表。
  * `ATMusicWatchApp.swift`：watchOS App 独立入口。

---

## 4. 调用 Apple Music 原生系统级能力清单

| 功能 | 调用的 Apple 系统框架/组件 | 达成的流畅体验 |
| :--- | :--- | :--- |
| **隔空播放 (AirPlay)** | `AVKit` / `AVRoutePickerView` | 在 iPad 侧栏与播放器内部一键呼出系统音响流转菜单，无缝连接 HomePod、Apple TV、AirPods。 |
| **锁屏与控制中心** | `MediaPlayer` / `MPNowPlayingInfoCenter` | 系统级大图 Artwork 响应、精准剩余时间、控制中心无损格式标识。 |
| **外设与手表远程控制** | `MediaPlayer` / `MPRemoteCommandCenter` | 响应锁屏、耳机手势、CarPlay 与手表的播放/暂停、收藏曲目、±15s 快进快退与进度拖拽。 |
| **硬件音量同步** | `MediaPlayer` / `MPVolumeView` | 软硬件音量即时同步，无任何软件模拟延迟。 |
| **音频会话守护** | `AVFoundation` / `AVAudioSession` | 智能处理来电中断恢复、耳机拔出自动暂停，保障后台长效播放。 |

---

## 5. 项目完整备份确认

在执行本次代码架构升级前，已于系统本地完成全量快照备份：
* **备份存放路径**：
  `/Users/tangfengjing/gemini/app_music/backup_20260930_before_ipad_redesign/AT-Music-main`
