import SwiftUI

struct JellyfinLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var jellyfin = JellyfinAPI.shared

    @State private var host: String = ""
    @State private var account: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

                ScrollView {
                    VStack(spacing: 20) {
                        headerCard
                        accountCard
                        actionButtons
                        instructionsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Jellyfin 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Color.atmusicAmber)
                }
            }
            .onAppear {
                host = jellyfin.host
                account = jellyfin.account
                password = jellyfin.storedPassword
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.atmusicAmber)
                Text("Jellyfin")
                    .font(ATMusicFont.appFont(16, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
            }
            Text("连接自建 Jellyfin 媒体服务器，浏览其中的音乐库、歌单并播放")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("服务器与账号")
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)

            VStack(spacing: 10) {
                HStack {
                    Text("地址")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("https://your-server.com", text: $host)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("账号")
                        .font(ATMusicFont.appFont(14))
                        .frame(width: 50, alignment: .leading)
                    TextField("用户名", text: $account)
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
                    SecureField("密码", text: $password)
                        .font(ATMusicFont.appFont(14))
                }
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await performLogin() }
            } label: {
                HStack {
                    if isLoading {
                        ProgressView().tint(.white)
                    }
                    Text(jellyfin.isLoggedIn ? "保存并重新连接" : "登录并连接")
                        .font(ATMusicFont.appFont(15, .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.atmusicAmber, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            }
            .disabled(isLoading || host.isEmpty || account.isEmpty || password.isEmpty)
            .buttonStyle(GlassPressButtonStyle())

            if jellyfin.isLoggedIn {
                Button(role: .destructive) {
                    jellyfin.logout()
                    ToastCenter.shared.show("已退出 Jellyfin 登录")
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
            Text("说明")
                .font(ATMusicFont.appFont(13, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            Text("地址需包含协议头（http:// 或 https://），不要带末尾斜杠，程序会自动拼接。登录成功后 AccessToken 与密码只存放在系统钥匙串中，不会写进代码或日志。")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func performLogin() async {
        isLoading = true
        errorMessage = nil
        do {
            try await jellyfin.configure(host: host, account: account, password: password)
            await MainActor.run {
                isLoading = false
                ToastCenter.shared.show("Jellyfin 连接成功")
                dismiss()
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
