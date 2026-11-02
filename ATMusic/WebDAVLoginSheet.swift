import SwiftUI

struct WebDAVLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var webdav = WebDAVAPI.shared

    @State private var host: String = ""
    @State private var account: String = ""
    @State private var password: String = ""
    @State private var musicRoot: String = "/"

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

                ScrollView {
                    VStack(spacing: 20) {
                        headerCard
                        serverCard
                        accountCard
                        actionButtons
                        instructionsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("WebDAV 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Color.atmusicAmber)
                }
            }
            .onAppear { loadCurrentValues() }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.system(size: 32))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 52, height: 52)
                .background { Circle().fill(Color.atmusicAmber.opacity(0.16)) }

            VStack(alignment: .leading, spacing: 4) {
                Text("通用 WebDAV 音乐源")
                    .font(ATMusicFont.appFont(16, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                HStack(spacing: 6) {
                    Circle()
                        .fill(webdav.isLoggedIn ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(webdav.isLoggedIn ? "已连接" : "未连接")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(webdav.isLoggedIn ? Color.green : Color.atmusicComment)
                }
            }
            Spacer()
        }
        .padding(16)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "server.rack").foregroundStyle(Color.atmusicAmber)
                Text("服务器地址").font(ATMusicFont.appFont(14, .semibold)).foregroundStyle(Color.atmusicLabel)
                Spacer()
            }

            VStack(spacing: 10) {
                HStack {
                    Text("地址").font(ATMusicFont.appFont(14)).frame(width: 60, alignment: .leading)
                    TextField("例如 https://nas.example.com:5006/webdav", text: $host)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("根目录").font(ATMusicFont.appFont(14)).frame(width: 60, alignment: .leading)
                    TextField("音乐所在路径，默认 / ", text: $musicRoot)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }

            Text("「根目录」是 WebDAV 服务器上存放音乐文件的路径，留空则扫描整个服务器根目录。")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
        }
        .padding(16)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("账号与密码")
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)

            VStack(spacing: 10) {
                HStack {
                    Text("账号").font(ATMusicFont.appFont(14)).frame(width: 50, alignment: .leading)
                    TextField("WebDAV 用户名", text: $account)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("密码").font(ATMusicFont.appFont(14)).frame(width: 50, alignment: .leading)
                    SecureField("WebDAV 密码", text: $password)
                        .font(ATMusicFont.appFont(14))
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
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await performLogin() }
            } label: {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    Text(webdav.isLoggedIn ? "保存并重新连接" : "连接")
                        .font(ATMusicFont.appFont(15, .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.atmusicAmber, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            }
            .disabled(isLoading || host.isEmpty || account.isEmpty)
            .buttonStyle(GlassPressButtonStyle())

            if webdav.isLoggedIn {
                Button(role: .destructive) {
                    webdav.logout()
                    ToastCenter.shared.show("已退出 WebDAV 登录")
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

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("说明：")
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            Text("1. 几乎所有 NAS（群晖/威联通/铁威马等）都可以在控制面板开启 WebDAV 服务。\n2. 专辑/艺术家分类基于您的文件夹结构自动归纳（建议整理成「艺术家/专辑/歌曲」的目录层级）。\n3. 歌单会以 .m3u 文件形式保存在根目录下的 ATMusicPlaylists 文件夹中。\n4. 不支持读取或写入音频文件内嵌标签与歌词；只会尝试读取同名 .lrc 文件作为歌词。")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private func loadCurrentValues() {
        host = webdav.host
        account = webdav.account
        musicRoot = webdav.musicRoot
        password = webdav.storedPassword
    }

    private func performLogin() async {
        isLoading = true
        errorMessage = nil
        do {
            try await webdav.configure(host: host, account: account, password: password, musicRoot: musicRoot)
            isLoading = false
            ToastCenter.shared.show("WebDAV 连接成功！")
            dismiss()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            ToastCenter.shared.show("连接失败: \(error.localizedDescription)")
        }
    }
}
