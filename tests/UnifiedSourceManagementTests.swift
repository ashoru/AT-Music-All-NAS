import Foundation

final class TestCredentialBackend: CredentialBackend, @unchecked Sendable {
    var values: [String: String] = [:]
    var failWrites = false
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String, key: String) -> Bool {
        guard !failWrites else { return false }
        values[key] = value
        return true
    }
    func remove(_ key: String) -> Bool { values.removeValue(forKey: key) != nil }
}

@main
enum UnifiedSourceManagementTests {
    static func main() {
        var passedAssertions = 0

        func assertTrue(_ condition: Bool, _ label: String) {
            precondition(condition, "❌ 断言失败: \(label)")
            passedAssertions += 1
        }

        func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            precondition(actual == expected, "❌ 断言失败 [\(label)]: 期望 \(expected), 实际 \(actual)")
            passedAssertions += 1
        }

        print("🚀 开始执行「统一歌曲与来源管理」自动化回归测试...")

        // ==========================================
        // 模块 1: 歌曲版本识别与防误合并机制
        // ==========================================
        print("▶ 测试 1: 版本类型自动识别")
        let vStudio = SongVersionKind.detect(title: "七里香", artist: "周杰伦")
        assertEqual(vStudio, .studio, "标准原版识别")

        let vLive1 = SongVersionKind.detect(title: "晴天 (Live)", artist: "周杰伦")
        assertEqual(vLive1, .live, "括号Live识别")

        let vLive2 = SongVersionKind.detect(title: "稻香 - 2008现场演唱会版", artist: "周杰伦")
        assertEqual(vLive2, .live, "后缀现场版识别")

        let vInst = SongVersionKind.detect(title: "青花瓷 (伴奏)", artist: "周杰伦")
        assertEqual(vInst, .instrumental, "伴奏识别")

        let vKaraoke = SongVersionKind.detect(title: "夜曲 (Karaoke Off Vocal)", artist: "周杰伦")
        assertEqual(vKaraoke, .instrumental, "Karaoke纯伴奏识别")

        let vRemix = SongVersionKind.detect(title: "双截棍 (Remix DJ版)", artist: "周杰伦")
        assertEqual(vRemix, .remix, "混音Remix识别")

        let vCover = SongVersionKind.detect(title: "安静 (Cover)", artist: "张三")
        assertEqual(vCover, .cover, "翻唱Cover识别")

        let vSpedUp = SongVersionKind.detect(title: "告白气球 (Sped Up 加速版)", artist: "周杰伦")
        assertEqual(vSpedUp, .speedup, "调速版识别")

        print("▶ 测试 2: 跨版本严格防误合并")
        let songStudio = UnifiedSong(
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            versionKind: .studio,
            duration: 269
        )
        let songLive = UnifiedSong(
            title: "晴天 (Live)",
            artist: "周杰伦",
            album: "无与伦比演唱会",
            versionKind: .live,
            duration: 295
        )
        let songInst = UnifiedSong(
            title: "晴天 (伴奏)",
            artist: "周杰伦",
            album: "叶惠美伴奏带",
            versionKind: .instrumental,
            duration: 269
        )
        let songCover = UnifiedSong(
            title: "晴天 (翻唱版)",
            artist: "网络歌手",
            album: "翻唱合集",
            versionKind: .cover,
            duration: 265
        )

        assertTrue(!songStudio.canSafelyMerge(with: songLive), "现场版绝不能合并入录音室版")
        assertTrue(!songStudio.canSafelyMerge(with: songInst), "伴奏绝不能合并入原版")
        assertTrue(!songStudio.canSafelyMerge(with: songCover), "翻唱版绝不能合并入原唱")
        assertTrue(!songLive.canSafelyMerge(with: songInst), "现场版与伴奏不能合并")

        print("▶ 测试 3: 同版本多来源安全合并")
        var songNetEase = UnifiedSong(
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            versionKind: .studio,
            duration: 269,
            sources: [
                SongSourceRecord(
                    id: "netease:186016",
                    sourceType: .netease,
                    remoteId: "186016",
                    title: "晴天",
                    artist: "周杰伦",
                    album: "叶惠美",
                    duration: 269
                )
            ]
        )
        let songQQ = UnifiedSong(
            title: "晴天",
            artist: "Jay Chou",
            album: "叶惠美",
            versionKind: .studio,
            duration: 270,
            sources: [
                SongSourceRecord(
                    id: "qq:0039MnYb0qxYAc",
                    sourceType: .qq,
                    remoteId: "0039MnYb0qxYAc",
                    title: "晴天",
                    artist: "Jay Chou",
                    album: "叶惠美",
                    duration: 270,
                    extraAttributes: ["qqMid": "0039MnYb0qxYAc"]
                )
            ]
        )
        assertTrue(songNetEase.canSafelyMerge(with: songQQ), "同版本、同曲目、中英文别名歌手应允许安全合并")

        songNetEase.addOrUpdateSource(songQQ.sources[0])
        assertEqual(songNetEase.sources.count, 2, "成功合并为两来源")
        assertTrue(songNetEase.sources.contains(where: { $0.sourceType == .netease }), "保留网易云来源")
        assertTrue(songNetEase.sources.contains(where: { $0.sourceType == .qq }), "保留QQ音乐来源")

        let strategyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ATMusicPhase3-\(UUID().uuidString)", isDirectory: true)
        let strategyDefaultsSuite = "ATMusicPhase3Defaults-\(UUID().uuidString)"
        let strategyDefaults = UserDefaults(suiteName: strategyDefaultsSuite)!
        let strategyStore = UnifiedSongStore(directory: strategyRoot, defaults: strategyDefaults)
        let strategyNetEase = Song(id: 1701, name: "晴天", artists: "周杰伦", album: "叶惠美", coverURL: nil, duration: 269, source: .netease)
        let strategyQQ = Song(id: 2701, name: "晴天", artists: "Jay Chou", album: "叶惠美", coverURL: nil, duration: 269, source: .qq, qqMid: "phase3-qq-mid")
        _ = try! strategyStore.importLegacySong(strategyNetEase)
        _ = try! strategyStore.importLegacySong(strategyQQ)
        let qqAlternatives = strategyStore.alternateSongs(for: strategyNetEase, preferredSource: .qq)
        assertTrue(qqAlternatives.first?.source == .qq, "混合歌单优先QQ时选择QQ来源")
        assertEqual(qqAlternatives.first?.qqMid, "phase3-qq-mid", "备用来源保留QQ原始songmid")
        try? FileManager.default.removeItem(at: strategyRoot)
        strategyDefaults.removePersistentDomain(forName: strategyDefaultsSuite)

        // ==========================================
        // 模块 2: 歌手与别名规范化测试
        // ==========================================
        print("▶ 测试 4: 简繁体与中英文别名归并")
        assertEqual(SongIdentityNormalizer.toSimplified("周杰倫"), "周杰伦", "繁体转简体")
        assertEqual(SongIdentityNormalizer.toSimplified("陳奕迅"), "陈奕迅", "繁体转简体2")
        assertTrue(SongIdentityNormalizer.isArtistCompatible(artistA: "周杰伦", artistB: "Jay Chou"), "周杰伦与Jay Chou别名兼容")
        assertTrue(SongIdentityNormalizer.isArtistCompatible(artistA: "林俊杰", artistB: "JJ Lin"), "林俊杰与JJ Lin别名兼容")
        assertTrue(SongIdentityNormalizer.isArtistCompatible(artistA: "王菲", artistB: "Faye Wong"), "王菲与Faye Wong别名兼容")
        assertTrue(!SongIdentityNormalizer.isArtistCompatible(artistA: "周杰伦", artistB: "林俊杰"), "不同歌手不兼容")

        // ==========================================
        // 模块 3: 平台适配器与能力清单
        // ==========================================
        print("▶ 测试 5: 平台适配器注册与能力清单校验")
        let registry = PlatformRegistry.shared
        let neCaps = registry.capabilities(for: .netease)
        assertTrue(neCaps.canSearchSongs && neCaps.supportsLyrics && neCaps.supportsComments, "网易云能力清单正确")

        let qqCaps = registry.capabilities(for: .qq)
        assertTrue(qqCaps.canSearchSongs && qqCaps.supportsLyrics && !qqCaps.supportsComments, "QQ音乐能力清单正确")

        let synoCaps = registry.capabilities(for: .synology)
        assertTrue(synoCaps.requiresAccount && synoCaps.supportsDownload, "群晖NAS能力清单正确")

        let localCaps = registry.capabilities(for: .local)
        assertTrue(localCaps.supportsLyrics && !localCaps.requiresAccount, "本地音乐能力清单正确")

        // ==========================================
        // 模块 4: 群晖 NAS 服务器与账号隔离
        // ==========================================
        print("▶ 测试 6: NAS 服务器与账号作用域隔离")
        let synoRecordServerA = SongSourceRecord(
            id: "synology:192.168.1.100:5000/admin:1001",
            sourceType: .synology,
            remoteId: "1001",
            serverScope: "192.168.1.100:5000/admin",
            title: "NAS歌曲A",
            artist: "歌手A",
            album: "专辑A",
            duration: 180
        )
        let synoRecordServerB = SongSourceRecord(
            id: "synology:nas.mycompany.com:5001/guest:1001",
            sourceType: .synology,
            remoteId: "1001",
            serverScope: "nas.mycompany.com:5001/guest",
            title: "NAS歌曲B",
            artist: "歌手B",
            album: "专辑B",
            duration: 180
        )
        assertTrue(synoRecordServerA.id != synoRecordServerB.id, "不同服务器/账号即使 remoteId 相同，ID 也不冲突")
        assertEqual(synoRecordServerA.serverScope, "192.168.1.100:5000/admin", "正确记录服务器作用域A")
        assertEqual(synoRecordServerB.serverScope, "nas.mycompany.com:5001/guest", "正确记录服务器作用域B")

        // ==========================================
        // 模块 5: 歌曲与旧版模型双向无损兼容
        // ==========================================
        print("▶ 测试 7: 旧版 Song 与 UnifiedSong 双向互转")
        let legacySong = Song(
            id: 123456,
            name: "夜曲",
            artists: "周杰伦",
            album: "十一月的萧邦",
            coverURL: URL(string: "https://example.com/cover.jpg"),
            duration: 226,
            source: .qq,
            qqMid: "001JtG8v2beqlZ",
            qqMediaMid: "002abcXYZ",
            fee: 1
        )
        let unifiedFromLegacy = UnifiedSong(legacySong: legacySong)
        assertEqual(unifiedFromLegacy.title, "夜曲", "歌名保持一致")
        assertEqual(unifiedFromLegacy.artist, "周杰伦", "歌手保持一致")
        assertEqual(unifiedFromLegacy.sources.count, 1, "包含1个来源")
        assertEqual(unifiedFromLegacy.sources[0].sourceType, .qq, "来源为QQ")
        assertEqual(unifiedFromLegacy.sources[0].extraAttributes["qqMid"], "001JtG8v2beqlZ", "保留qqMid")
        assertEqual(unifiedFromLegacy.sources[0].extraAttributes["qqMediaMid"], "002abcXYZ", "保留qqMediaMid")

        let exportedBack = unifiedFromLegacy.toLegacySong()!
        assertEqual(exportedBack.name, legacySong.name, "反向导出歌名一致")
        assertEqual(exportedBack.artists, legacySong.artists, "反向导出歌手一致")
        assertEqual(exportedBack.source, .qq, "反向导出平台一致")
        assertEqual(exportedBack.qqMid, "001JtG8v2beqlZ", "反向导出qqMid一致")
        assertEqual(exportedBack.qqMediaMid, "002abcXYZ", "反向导出qqMediaMid一致")
        assertEqual(exportedBack.fee, 1, "反向导出fee一致")

        // ==========================================
        // 模块 6: 本地音频文件相对路径与防同名覆盖
        // ==========================================
        print("▶ 测试 8: 本地文件命名安全与相对路径管理")
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ATMusicPhase2-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = testRoot.appendingPathComponent("sources", isDirectory: true)
        let docsDir = testRoot.appendingPathComponent("Documents", isDirectory: true)
        let indexDir = testRoot.appendingPathComponent("index", isDirectory: true)
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        let tempFile1 = sourceDir.appendingPathComponent("test1.mp3")
        let tempFile2 = sourceDir.appendingPathComponent("test2.mp3")
        try! Data("dummy-audio-1".utf8).write(to: tempFile1)
        try! Data("dummy-audio-2".utf8).write(to: tempFile2)

        let fileManager = LocalAudioFileManager(documents: docsDir, directory: indexDir)
        let managed1 = try! fileManager.registerFile(
            sourceTempURL: tempFile1,
            songId: "usong_001",
            originalFilename: "晴天.mp3",
            kind: .userImported
        )
        let managed2 = try! fileManager.registerFile(
            sourceTempURL: tempFile2,
            songId: "usong_002",
            originalFilename: "晴天.mp3", // 同名文件！
            kind: .userDownloaded
        )

        assertTrue(managed1.relativePath != managed2.relativePath, "两首同名歌曲必须分配不同的内部相对路径，绝不覆盖")
        assertTrue(managed1.id != managed2.id, "文件ID唯一")
        assertTrue(managed1.relativePath.hasPrefix("ATMusicAudio/"), "使用相对路径存储")
        assertEqual(managed1.kind, .userImported, "类型为用户导入")
        assertEqual(managed2.kind, .userDownloaded, "类型为用户下载")

        // 缓存清理隔离测试：仅清理临时缓存，用户导入与下载绝不删除
        let removedCacheCount = try! fileManager.clearPlaybackCacheOnly()
        assertTrue(fileManager.file(forSongId: "usong_001") != nil, "用户导入文件未被清理")
        assertTrue(fileManager.file(forSongId: "usong_002") != nil, "用户下载文件未被清理")
        _ = removedCacheCount

        // 清理测试文件
        try! fileManager.deleteFile(id: managed1.id)
        try! fileManager.deleteFile(id: managed2.id)
        try? FileManager.default.removeItem(at: testRoot)

        // ==========================================
        // 模块 7: 凭据安全存储与迁移
        // ==========================================
        print("▶ 测试 9: 凭据安全存储读取与更新")
        let credStore = SecureCredentialStore(backend: TestCredentialBackend())
        let testSecretKey = "test.synology.password"
        let testSecretVal = "MySecretP@ssw0rd!2026"
        _ = credStore.setSecret(testSecretVal, for: testSecretKey)
        let readVal = credStore.secret(for: testSecretKey)
        assertEqual(readVal, testSecretVal, "密码安全写入与读取一致")
        _ = credStore.deleteSecret(for: testSecretKey)
        assertTrue(credStore.secret(for: testSecretKey) == nil, "凭据安全删除")
        let migrationSuite = "ATMusicPhase2Migration-\(UUID().uuidString)"
        let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
        migrationDefaults.set("legacy-secret", forKey: "atmusic.synology.password")
        let migrationBackend = TestCredentialBackend()
        migrationBackend.failWrites = true
        let failingStore = SecureCredentialStore(backend: migrationBackend)
        assertTrue(!failingStore.migrateLegacyPassword(defaults: migrationDefaults, destinationKey: "synology.password.scope"), "钥匙串失败时迁移报告失败")
        assertEqual(migrationDefaults.string(forKey: "atmusic.synology.password"), "legacy-secret", "钥匙串失败时保留旧密码")
        migrationDefaults.removePersistentDomain(forName: migrationSuite)

        // ==========================================
        // 模块 8: 日志脱敏与机密数据保护
        // ==========================================
        print("▶ 测试 10: 敏感信息日志脱敏")
        let logRaw1 = "NAS login failed: account=admin passwd=superSecret123&session=AudioStation"
        let sanitized1 = ATMusicLogSanitizer.sanitize(logRaw1)
        assertTrue(!sanitized1.contains("superSecret123"), "密码被成功过滤脱敏")
        assertTrue(sanitized1.contains("passwd=***"), "正确打码掩码")

        let logRaw2 = "Stream url fetched: https://nas.local:5000/stream.cgi?id=123&_sid=abcXYZ987654Token"
        let sanitized2 = ATMusicLogSanitizer.sanitize(logRaw2)
        assertTrue(!sanitized2.contains("abcXYZ987654Token"), "会话_sid被成功脱敏")
        assertTrue(sanitized2.contains("_sid=***"), "正确遮蔽_sid")

        let logRaw3 = "QQ request with vkey=abcdef0123456789 and cookie: MUSIC_U=mySecretNeteaseCookieVal;"
        let sanitized3 = ATMusicLogSanitizer.sanitize(logRaw3)
        assertTrue(!sanitized3.contains("abcdef0123456789"), "vkey被脱敏")
        assertTrue(!sanitized3.contains("mySecretNeteaseCookieVal"), "Cookie被脱敏")

        print("==================================================")
        print("🎉 全部 \(passedAssertions) 项断言测试顺利通过！")
        print("==================================================")
    }
}
