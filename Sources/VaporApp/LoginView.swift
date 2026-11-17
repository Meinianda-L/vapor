import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VaporKit

/// Vapor's own Steam sign-in, shown instead of the Wine client's login window.
struct LoginView: View {
    @EnvironmentObject var engine: EngineModel
    @State private var account = ""
    @State private var password = ""
    @State private var remember = true
    @State private var code = ""
    @State private var forgetting: SteamUI.LoginUser?
    @State private var switching: String?
    @FocusState private var focus: Field?

    private enum Field { case account, password, code }

    private var login: SteamUI.Login? { engine.login }
    private var passwordSession: SteamUI.Login? { login.flatMap { $0.kind == "password" ? $0 : nil } }
    private var busy: Bool { switching != nil || passwordSession?.status == "signingIn" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(engine.strings("Login_EnterCredentials") ?? String(localized: "登录")).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
                if !engine.loginUsers.isEmpty { remembered }
                HStack(alignment: .top, spacing: 0) {
                    passwordColumn.frame(width: 290, alignment: .leading)
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 250).padding(.horizontal, 40)
                    qrColumn.frame(width: 204, alignment: .leading)
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .onAppear {
            engine.refreshLoginUsers()
            engine.startQRLogin()
            focus = .account
        }
        .onDisappear {
            password = ""
            engine.cancelLogin()
        }
        .onChange(of: login?.status) { _, status in
            // An expired code is replaced at once; a network failure waits for the 刷新 link instead of looping.
            if status == "failed", login?.kind == "qr", login?.failure == 2 { engine.startQRLogin() }
        }
        .onChange(of: login?.eresult) { _, _ in code = "" }
        .task(id: switching) {
            guard switching != nil else { return }
            try? await Task.sleep(for: .seconds(25))
            switching = nil
        }
    }

    // MARK: remembered accounts

    private var remembered: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: String(localized: "选择账户"))
            HStack(alignment: .top, spacing: 22) {
                ForEach(engine.loginUsers) { user in rememberedUser(user) }
            }
            if let user = forgetting {
                HStack(spacing: 14) {
                    Text(String(localized: "忘记 \(user.accountName)？此设备将不再保存这个账户。")).foregroundStyle(Theme.secondary)
                    link(String(localized: "忘记"), color: Theme.bad) { engine.forgetUser(user.accountName); forgetting = nil }
                    link(String(localized: "取消")) { forgetting = nil }
                }
                .font(.system(size: 12))
            }
            if let name = switching {
                Text(String(localized: "正在切换到 \(name)…")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func rememberedUser(_ user: SteamUI.LoginUser) -> some View {
        VStack(spacing: 6) {
            Button {
                if user.remember {
                    switching = user.accountName
                    engine.switchUser(user.accountName)
                } else {
                    account = user.accountName
                    focus = .password
                }
            } label: {
                VStack(spacing: 7) {
                    AccountAvatar(url: user.avatar, name: user.persona, size: 44)
                    Text(user.persona.isEmpty ? user.accountName : user.persona)
                        .font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                        .frame(maxWidth: 84)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(user.remember ? String(localized: "以 \(user.accountName) 登录") : String(localized: "需要重新输入密码"))
            link(String(localized: "忘记"), color: Theme.tertiary) { forgetting = user }.font(.system(size: 11))
        }
    }

    // MARK: account name and password

    private var passwordColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: String(localized: "用账户名称登录"))
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "账户名称")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                field { TextField("", text: $account).focused($focus, equals: .account).onSubmit { focus = .password } }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "密码")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                field { SecureField("", text: $password).focused($focus, equals: .password).onSubmit(submit) }
            }
            Toggle(String(localized: "记住我"), isOn: $remember).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.text)
            if let session = passwordSession { progress(session) }
            if let message = errorMessage { Text(message).font(.system(size: 12)).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true) }
            Button(action: submit) {
                Text(engine.strings("Login_Login") ?? String(localized: "登录"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.text.opacity(canSubmit ? 1 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func field<F: View>(@ViewBuilder _ content: () -> F) -> some View {
        content()
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.hairline))
    }

    private var canSubmit: Bool { !account.isEmpty && !password.isEmpty && !busy }

    private func submit() {
        guard canSubmit else { return }
        code = ""
        engine.startPasswordLogin(account: account, password: password, remember: remember)
    }

    /// What the password session is waiting for, once the credentials are accepted.
    @ViewBuilder private func progress(_ session: SteamUI.Login) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.status == "signingIn" {
                Text(engine.strings("Login_WaitingForServer") ?? String(localized: "正在登录…")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if session.confirmations.contains(4) {
                Text(String(localized: "请在 Steam 手机应用中批准登录")).font(.system(size: 12)).foregroundStyle(Theme.text)
            }
            if session.needsCode { codeEntry(session) }
        }
    }

    private func codeEntry(_ session: SteamUI.Login) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.codeType == 3 ? String(localized: "输入 Steam 手机应用中的验证码") : String(localized: "输入发送到你电子邮箱的验证码"))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            field {
                TextField("", text: $code)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .focused($focus, equals: .code)
                    .onChange(of: code) { _, value in
                        let clean = String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(5))
                        if clean != value { code = clean }
                        if clean.count == 5 { engine.submitSteamGuardCode(clean, type: session.codeType) }
                    }
            }
            .frame(width: 140)
        }
        .onAppear { focus = .code }
    }

    /// Steam's own wording for each failure.
    private var errorMessage: String? {
        guard let login, login.kind == "password" else { return nil }
        switch (login.eresult, login.failure) {
        case (5, _): return engine.strings("Login_PasswordMismatch") ?? String(localized: "密码错误")
        case (65, _), (88, _): return engine.strings("Login_TwoFactorMismatch") ?? String(localized: "验证码错误")
        case (84, _), (_, 5): return engine.strings("Login_RateLimitExceeded") ?? String(localized: "最近登录尝试过于频繁。请稍后再试。")
        case (_, 2): return engine.strings("Login_SteamGuardExpired") ?? String(localized: "验证已过期，请重新登录。")
        case (_, 3): return engine.strings("Login_NoConnection") ?? String(localized: "连接 Steam 服务器失败")
        case (0, _), (1, _): return login.status == "failed" ? String(localized: "登录失败，请重试。") : nil
        case let (e, _): return String(localized: "登录失败（错误 \(e)）")
        }
    }

    // MARK: QR code

    private var qrColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: String(localized: "使用二维码登录"))
            let qr = login.flatMap { $0.kind == "qr" ? $0 : nil }
            ZStack {
                if let url = qr?.challengeURL, qr?.status != "failed" {
                    QRCodeView(text: url).opacity(qr?.remote == true ? 0.25 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surface).frame(width: 180, height: 180)
                }
            }
            .frame(width: 180, height: 180)
            if qr?.remote == true {
                Text(String(localized: "已扫描，请在手机上确认")).font(.system(size: 12)).foregroundStyle(Theme.text)
            } else if qr?.status == "failed" || (login != nil && qr == nil) {
                HStack(spacing: 10) {
                    Text(qr?.failure == 3 ? String(localized: "连接 Steam 服务器失败") : String(localized: "二维码不可用")).foregroundStyle(Theme.secondary)
                    link(String(localized: "刷新")) { engine.startQRLogin() }
                }
                .font(.system(size: 12))
            } else {
                Text(String(localized: "使用 Steam 手机应用扫描")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func link(_ title: String, color: Color = Theme.secondary, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).foregroundStyle(color)
    }
}

/// Rendered locally; modules are scaled by whole pixels so they stay sharp.
private struct QRCodeView: View {
    let text: String

    private static let context = CIContext()

    var body: some View {
        Group {
            if let image = Self.render(text) {
                let side = CGFloat(image.width * max(1, 156 / image.width))
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                    .frame(width: side, height: side)
                    .padding((180 - side) / 2)
                    .background(Color.white)
            } else {
                Color.clear
            }
        }
        .frame(width: 180, height: 180)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
