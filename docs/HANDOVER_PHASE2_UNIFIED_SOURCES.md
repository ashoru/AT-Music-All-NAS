# AT Music 阶段二交接文档：统一歌曲与来源管理

**版本基线**：1.6.5.10 (47)  
**更新时间**：2026-09-19  
**代码目录**：`/Users/tangfengjing/gemini/app_music/AT-Music-main`  
**测试验证**：`tests/UnifiedSourceManagementTests.swift`（56 项断言全部 PASS），`tests/ScrollDockStateTests.swift`（248 项断言全部 PASS）  
**修改前源码备份**：`/Users/tangfengjing/gemini/app_music/phase2-stage2-unified-sources/source-before-stage2.tgz`

---

## 一、阶段二整体设计与解决的问题

在多平台（网易云、QQ音乐、酷狗、群晖 NAS、本地音频）聚合播放器中，传统设计往往将“歌曲”等同于“平台特定的数字 ID + 临时播放链接”。这会导致：
1. **身份冲突**：不同平台数字 ID 相互撞车。
2. **版本混淆**：现场版（Live）、伴奏（Instrumental）、翻唱（Cover）与录音室原版被错误合并替换。
3. **NAS/平台耦合**：换个 NAS 账号或离线后，歌单中的记录丢失或 ID 失效。
4. **同名文件相互覆盖**：本地下载或导入同名歌曲直接覆盖目标文件。
5. **安全隐患**：NAS 密码保存在 UserDefaults 明文；敏感 token、_sid 与密码在日志中未脱敏输出。

阶段二通过**三层实体模型**、**平台适配层**、**四层独立管理**与**安全存储/脱敏中心**彻底解决了以上问题。

---

## 二、关键新增与改动文件清单

### 1. `ATMusic/UnifiedSongModel.swift`（核心数据模型层）
- **三层架构设计**：
  - **歌曲版本层 (`UnifiedSong`)**：艺术作品录音版本实体，拥有稳定 Canonical ID（`usong_<hash>`），携带规范化标题、歌手、专辑与 `versionKind`。
  - **来源记录层 (`SongSourceRecord`)**：各平台身份实体（`netease:186016`、`qq:0039MnYb0qxYAc`、`synology:<scope>:<id>`、`local:<fileId>`），保留平台专有字段（如 `qqMid`、`kugouHash`、`serverScope`）。
  - **实际播放资源层 (`PlayableResource`)**：运行时动态解析出的真实流地址或本地文件路径，包含音质、有效期、鉴权请求头（Referer/Cookie）。
- **版本分类识别引擎 (`SongVersionKind`)**：
  - 自动识别：`.studio`（录音室原版）、`.live`（现场版/演唱会）、`.instrumental`（伴奏/纯音乐）、`.remix`（混音/DJ）、`.cover`（翻唱）、`.speedup`（调速/加速版）、`.acoustic`（不插电）。
  - **严格防误合并机制 (`canSafelyMerge`)**：铁律规定 `versionKind` 不同的录音版本绝不自动合并，翻唱绝不替代原唱，现场版绝不替换录音室版。
- **歌手与别名规范化引擎 (`SongIdentityNormalizer`)**：
  - 支持繁体自动转简体（“周杰倫” -> “周杰伦”）。
  - 支持常用中英文艺名别名对照（“Jay Chou” <-> “周杰伦”，“Eason Chan” <-> “陈奕迅”等）。
- **双向兼容桥接**：
  - `init(legacySong:serverScope:)`：无损升级现有旧版 `Song`。
  - `toLegacySong(preferredSource:)`：反向导出为现有界面和播放器可直接消费的 `Song` 对象。

### 2. `ATMusic/PlatformAdapter.swift`（平台适配层与能力清单）
- **统一接口 (`MusicPlatformAdapter`)**：
  - `platformType: SongSourceType`
  - `capabilities: PlatformCapabilities`
  - `resolvePlayableResource(...)`
  - `fetchLyrics(...)`
  - `isConfigured()` / `isLoggedIn()`
- **能力清单 (`PlatformCapabilities`)**：
  - 明确各平台是否支持歌曲/歌手/专辑/歌单搜索，是否支持分页，是否需账号，音质列表，下载支持，歌词与评论支持。
- **5 个标准平台适配器**：
  - `NetEasePlatformAdapter`（网易云）
  - `QQMusicPlatformAdapter`（QQ音乐）
  - `KugouPlatformAdapter`（酷狗音乐）
  - `SynologyPlatformAdapter`（群晖 NAS，支持多服务器与账号作用域隔离）
  - `LocalPlatformAdapter`（本地音频与本地歌词）
- **统一调度与故障隔离 (`PlatformRegistry`)**：
  - 单个平台接口超时或异常时在内部捕获并打标，绝不影响其他平台的搜索和播放。

### 3. `ATMusic/UnifiedSongStore.swift`（数据与文件存储中心）
- **四层分别管理**：
  1. **元数据管理 (`UnifiedSongStore`)**：多来源智能合并与规范化存储。
  2. **音频文件管理 (`LocalAudioFileManager`)**：
     - 文件用内部安全唯一 ID（`aud_<uuid>_<timestamp>.<ext>`）命名，彻底避免同名歌曲覆盖。
     - 采用相对路径（`ATMusicAudio/...`）记录，运行时与当前沙盒动态拼接，解决覆盖安装沙盒 UUID 变化问题。
     - 三类文件隔离：`userImported`（用户导入）、`userDownloaded`（主动下载）、`playbackCache`（临时缓存）。清理缓存仅删除 `playbackCache`。
  3. **下载任务记录 (`DownloadTaskRecord`)**：状态机管理（pending, downloading, paused, completed, failed）。
  4. **索引管理**：与 NAS 内存推荐数据分离。
- **旧本地歌单无缝迁移**：
  - `LocalLibraryStore` 在初始化时自动将本地歌单全部注册至 `UnifiedSongStore`，旧收藏与歌单数据 100% 完整保留。

### 4. `ATMusic/SecureCredentialStore.swift`（凭据安全加密存储）
- 基于 iOS Keychain 钥匙串（`kSecClassGenericPassword`，服务名 `com.atmusic.music.credentials`）。
- 启动时自动检测 UserDefaults 中遗留的 `atmusic.synology.password`，成功写入 Keychain 后立即从 UserDefaults 抹除明文。

### 5. `ATMusic/ATMusicLogSanitizer.swift` 与 `ATMusic/ATMusicLogger.swift`（全局日志脱敏）
- 自动识别并遮蔽：`password=`、`passwd=`、`pwd=`、`_sid=`、`sid=`、`vkey=`、`token=`、`cookie=`、`MUSIC_U=`、`Authorization:`。
- `ATMusicLogger.shared.log(...)` 写入文件和内存缓存前全局过滤，杜绝机密泄露。

### 6. `ATMusic/DownloadManager.swift` 修复
- 补充了此前缺失的群晖 NAS 独立下载分支（`song.source == .synology` 直接从 Audio Station 构造原文件流，不再错误套用网易云下载逻辑）。

---

## 三、自动化测试与验证方法

本地回归测试套件位于 `tests/UnifiedSourceManagementTests.swift`，可通过终端直接编译和运行：

```bash
/tmp/atmusic-unified-source-tests
```
全部 56 项断言 PASS。
