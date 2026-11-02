import SwiftUI

struct SynologyLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var indexController = NASIndexController.shared
    @AppStorage("atmusic.nas.index.autoAfterWrite") private var autoReindexAfterWrite = true
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var syncManager = NASUserSyncManager.shared

    // 局域网 (LAN) 设置
    @State private var lanHost: String = ""
    @State private var lanPortStr: String = "5000"
    @State private var lanHTTPS: Bool = false

    // 公网 (WAN) 设置
    @State private var wanHost: String = ""
    @State private var wanPortStr: String = "5000"
    @State private var wanHTTPS: Bool = false

    // 蜂窝网络转码省流
    @AppStorage("atmusic.nas.transcodeOnCellular") private var transcodeOnCellular = false

    // 凭证
    @State private var account: String = ""
    @State private var password: String = ""
    @State private var otpCode: String = ""

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

                ScrollView {
                    VStack(spacing: 20) {
                        headerCard

                        if synology.isLoggedIn {
                            userSyncCard
                        }

                        lanConfigCard

                        wanConfigCard

                        cellularConfigCard

                        accountCard

                        actionButtons

                        instructionsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("群晖 NAS 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundStyle(Color.atmusicAmber)
                }
            }
            .onAppear {
                loadCurrentValues()
            }
        }
    }

    private var userSyncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.atmusicAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("用户数据云同步与备份")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("自动同步本地歌单、红心收藏、播放历史与个性化设置")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
            }

            Divider().opacity(0.15)

            Toggle(isOn: Binding(get: { syncManager.autoSyncEnabled }, set: { syncManager.autoSyncEnabled = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动静默同步")
                        .font(ATMusicFont.appFont(14, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("数据变更及应用启动/切后台时自动合并")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .tint(Color.atmusicAmber)

            HStack {
                Text("上次同步状态")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                Spacer()
                Text(syncManager.formattedLastSyncTime)
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicLabel)
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        await syncManager.backupToNAS(isManual: true)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if syncManager.isSyncing {
                            ProgressView().tint(Color.atmusicAmber).scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.icloud")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text("立即备份到 NAS")
                            .font(ATMusicFont.appFont(13, .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Color.atmusicAmber)
                }
                .disabled(syncManager.isSyncing)
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))

                Button {
                    Task {
                        await syncManager.restoreFromNAS(isManual: true)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.icloud")
                            .font(.system(size: 13, weight: .semibold))
                        Text("从 NAS 恢复同步")
                            .font(ATMusicFont.appFont(13, .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Color.atmusicLabel)
                }
                .disabled(syncManager.isSyncing)
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 52, height: 52)
                .background {
                    Circle()
                        .fill(Color.atmusicAmber.opacity(0.16))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Synology Audio Station")
                    .font(ATMusicFont.appFont(16, .bold))
                    .foregroundStyle(Color.atmusicLabel)

                HStack(spacing: 6) {
                    Circle()
                        .fill(synology.isLoggedIn ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    Text(synology.isLoggedIn ? "已连接并授权" : "未连接")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(synology.isLoggedIn ? Color.green : Color.atmusicComment)

                    if synology.isLoggedIn {
                        Text("·")
                            .foregroundStyle(Color.atmusicComment)
                        Text(synology.isLanActive ? "局域网直连 (\(synology.lanLatencyMs.map { "\($0)ms" } ?? "1ms"))" : "公网访问")
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(synology.isLanActive ? Color.atmusicAmber : Color.blue)
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 局域网直连配置 (LAN)

    private var lanConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "house.fill")
                    .foregroundStyle(Color.atmusicAmber)
                Text("家庭局域网直连 (LAN)")
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("千兆无损极速")
                    .font(ATMusicFont.appFont(11, .medium))
                    .foregroundStyle(Color.atmusicComment)
            }

            VStack(spacing: 10) {
                HStack {
                    Text("内网 IP")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 60, alignment: .leading)
                    TextField("例如 192.168.1.100 或 DiskStation", text: $lanHost)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("端口")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 60, alignment: .leading)
                    TextField("5000", text: $lanPortStr)
                        .font(ATMusicFont.appFont(14))
                        .keyboardType(.numberPad)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                Toggle(isOn: $lanHTTPS) {
                    Text("内网启用 HTTPS")
                        .font(ATMusicFont.appFont(14))
                }
                .padding(.horizontal, 4)
                .onChange(of: lanHTTPS) { enabled in
                    if enabled && lanPortStr == "5000" {
                        lanPortStr = "5001"
                    } else if !enabled && lanPortStr == "5001" {
                        lanPortStr = "5000"
                    }
                }
            }
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 外部公网访问配置 (WAN)

    private var wanConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(Color.blue)
                Text("外部公网访问 (WAN / DDNS)")
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("外出漫游访问")
                    .font(ATMusicFont.appFont(11, .medium))
                    .foregroundStyle(Color.atmusicComment)
            }

            VStack(spacing: 10) {
                HStack {
                    Text("公网地址")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 60, alignment: .leading)
                    TextField("DDNS 域名或公网 IP (选填)", text: $wanHost)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("端口")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 60, alignment: .leading)
                    TextField("5000", text: $wanPortStr)
                        .font(ATMusicFont.appFont(14))
                        .keyboardType(.numberPad)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                Toggle(isOn: $wanHTTPS) {
                    Text("公网启用 HTTPS")
                        .font(ATMusicFont.appFont(14))
                }
                .padding(.horizontal, 4)
                .onChange(of: wanHTTPS) { enabled in
                    if enabled && wanPortStr == "5000" {
                        wanPortStr = "5001"
                    } else if !enabled && wanPortStr == "5001" {
                        wanPortStr = "5000"
                    }
                }
            }
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 移动蜂窝网络优化

    private var cellularConfigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $transcodeOnCellular) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Color.atmusicAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("蜂窝网络下自动转码 (320kbps MP3)")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("外出省流模式，Wi-Fi 下始终保持原盘母带直出")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - DSM 账号凭据

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DSM 账号与安全鉴权")
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)

            VStack(spacing: 10) {
                HStack {
                    Text("账号")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("群晖用户名", text: $account)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("密码")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    SecureField("群晖密码", text: $password)
                        .font(ATMusicFont.appFont(14))
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("OTP")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("双重验证码 (若开启了 2FA，未开启请留空)", text: $otpCode)
                        .font(ATMusicFont.appFont(14))
                        .keyboardType(.numberPad)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await performLogin() }
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(synology.isLoggedIn ? "保存并重新连接" : "登录并连接")
                        .font(ATMusicFont.appFont(15, .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.atmusicAmber, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            }
            .disabled(isLoading || (lanHost.isEmpty && wanHost.isEmpty) || account.isEmpty)
            .buttonStyle(GlassPressButtonStyle())

            if synology.isLoggedIn {
                indexMaintenanceCard
            }

            if synology.isLoggedIn {
                Button(role: .destructive) {
                    Task {
                        await synology.logout()
                        ToastCenter.shared.show("已退出群晖登录")
                    }
                } label: {
                    Text("断开连接并登出")
                        .font(ATMusicFont.appFont(14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.red)
                }
                .buttonStyle(GlassPressButtonStyle())
            }
        }
    }

    /// NAS 音乐库索引维护：上传音频/封面后不必再去 DSM 网页端点「重新索引」。
    private var indexMaintenanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                Text("音乐库索引")
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text(indexController.snapshot.title)
                    .font(ATMusicFont.appFont(11, .medium))
                    .foregroundStyle(indexController.snapshot.isScanning ? Color.atmusicAmber : Color.atmusicComment)
            }

            if indexController.snapshot.isScanning {
                ProgressView(
                    value: Double(indexController.snapshot.percent ?? 0),
                    total: 100
                )
                .tint(Color.atmusicAmber)
            }

            if !indexController.snapshot.detail.isEmpty {
                Text(indexController.snapshot.detail)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    ATMusicHaptics.tap()
                    Task { await indexController.start() }
                } label: {
                    Label(indexController.snapshot.isScanning ? "扫描中…" : "立即重新扫描",
                          systemImage: "magnifyingglass.circle")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(indexController.isBusy || indexController.snapshot.isScanning || indexController.snapshot.phase == .unsupported)

                Button {
                    ATMusicHaptics.select()
                    indexController.refreshLocalLibraryCache()
                    ToastCenter.shared.show("已刷新曲库缓存")
                } label: {
                    Text("刷新曲库缓存")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if indexController.snapshot.isScanning {
                Button {
                    ATMusicHaptics.tap()
                    Task { await indexController.stop() }
                } label: {
                    Text("停止扫描")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Toggle(isOn: $autoReindexAfterWrite) {
                Text("写入文件后自动触发扫描")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicLabel)
            }
            .tint(Color.atmusicAmber)

            if let last = indexController.lastFinishedText {
                Text("上次完成：\(last)")
                    .font(ATMusicFont.appFont(10))
                    .foregroundStyle(Color.atmusicComment.opacity(0.85))
            }
        }
        .padding(14)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        .task { await indexController.probeIfNeeded() }
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("双通道智能路由说明：")
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            Text("1. 支持同时配置「内网 IP」与「公网 DDNS 域名」。\n2. 在家中连接家庭 Wi-Fi 时，系统优先走局域网千兆通道，低延迟、原盘无损直出。\n3. 外出时系统自动无缝切至公网通道，配合蜂窝转码保障流畅省流播放。\n4. 支持会话自动静默重签，避免长时间播放后令牌过期。")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func loadCurrentValues() {
        lanHost = synology.lanHost.isEmpty ? synology.host : synology.lanHost
        lanPortStr = "\(synology.lanPort)"
        lanHTTPS = synology.lanHTTPS

        wanHost = synology.wanHost
        wanPortStr = "\(synology.wanPort)"
        wanHTTPS = synology.wanHTTPS

        account = synology.account
        password = synology.savedPassword
    }

    private func performLogin() async {
        let lp = Int(lanPortStr) ?? 5000
        let wp = Int(wanPortStr) ?? 5000

        isLoading = true
        errorMessage = nil
        do {
            try synology.saveDualConfiguration(
                lanHost: lanHost,
                lanPort: lp,
                lanHTTPS: lanHTTPS,
                wanHost: wanHost,
                wanPort: wp,
                wanHTTPS: wanHTTPS,
                account: account,
                password: password
            )
            try await synology.login(otpCode: otpCode.isEmpty ? nil : otpCode)
            isLoading = false
            ToastCenter.shared.show("群晖 NAS 连接成功！")
            dismiss()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            ToastCenter.shared.show("连接失败: \(error.localizedDescription)")
        }
    }
}
