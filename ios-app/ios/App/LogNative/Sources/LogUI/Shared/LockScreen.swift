import SwiftUI
import AuthenticationServices
import CryptoKit
import Security
import LogCore

/// The sign-in screen: Google, an email and password (a free account), or the passcode (the
/// original log). Sign in with Apple is built but stays hidden until the app has a paid developer
/// account (SignInOptions.apple).
public struct LockScreen: View {
    @Environment(LogStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var mode: Mode = .choose
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var letters = false
    @State private var busy = false
    @State private var message: String?
    @State private var note: String?
    @FocusState private var focus: Field?

    enum Mode { case choose, signIn, create, passcode }
    enum Field { case email, password, code }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 48)
                logo
                switch mode {
                case .choose: chooser
                case .signIn, .create: emailForm
                case .passcode: passcodeForm
                }
                if let msg = message ?? store.errorMessage {
                    Text(msg).font(.subheadline).foregroundStyle(LogColor.critInk).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Text(note).font(.subheadline).foregroundStyle(LogColor.ink2).multilineTextAlignment(.center)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LogColor.bg.ignoresSafeArea())
        .disabled(busy)
    }

    private var logo: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LogColor.hero).frame(width: 72, height: 72)
                Text("L").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                Circle().fill(LogColor.accent).frame(width: 14, height: 14).offset(x: -12, y: -14)
            }
            .accessibilityHidden(true)
            Text("Log").font(.logNumber(34))
            Text(subtitle).font(.subheadline).foregroundStyle(LogColor.ink2).multilineTextAlignment(.center)
        }
    }

    private var subtitle: String {
        switch mode {
        case .choose: return "Track your GLP-1 doses, food, weight and training in one place."
        case .signIn: return "Sign in with your email."
        case .create: return "Make a free account. Your log is yours alone."
        case .passcode: return "Enter the passcode for the original log."
        }
    }

    // MARK: Choose

    private var chooser: some View {
        VStack(spacing: 12) {
            Button(action: google) {
                HStack(spacing: 10) {
                    Image(systemName: "g.circle.fill").font(.title3)
                    Text(busy ? "Opening Google…" : "Continue with Google").font(.headline)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(LogColor.hero)

            if SignInOptions.apple {
                SignInWithAppleButton(.continue, onRequest: appleRequest, onCompletion: appleDone)
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .clipShape(Capsule())
            }

            Button { switchTo(.create) } label: {
                Text("Create an account with email").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(LogColor.accent)

            Button("I already have an email account") { switchTo(.signIn) }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            Divider().padding(.vertical, 8)

            Button("Use a passcode instead") { switchTo(.passcode) }
                .font(.subheadline)
                .foregroundStyle(LogColor.ink2)
        }
    }

    // MARK: Email

    private var emailForm: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .modifier(FieldStyle())
            SecureField(mode == .create ? "Password (8 or more characters)" : "Password", text: $password)
                .textContentType(mode == .create ? .newPassword : .password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit(submitEmail)
                .modifier(FieldStyle())
            Button(action: submitEmail) {
                Text(busy ? "One moment…" : (mode == .create ? "Create account" : "Sign in"))
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(LogColor.accent)
            .disabled(email.isEmpty || password.count < (mode == .create ? 8 : 1))
            HStack {
                Button(mode == .create ? "I have an account" : "Create an account") { switchTo(mode == .create ? .signIn : .create) }
                Spacer()
                if mode == .signIn { Button("Forgot password?", action: reset) }
            }
            .font(.subheadline)
            Button("Back") { switchTo(.choose) }.font(.subheadline).foregroundStyle(LogColor.ink2).padding(.top, 6)
        }
        .onAppear { focus = .email }
    }

    // MARK: Passcode

    private var passcodeForm: some View {
        VStack(spacing: 12) {
            SecureField("Passcode", text: $code)
                .keyboardType(letters ? .asciiCapable : .numberPad)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.logNumber(24, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($focus, equals: .code)
                .submitLabel(.go)
                .onSubmit(submitPasscode)
                .modifier(FieldStyle())
            Button(action: submitPasscode) {
                Text(busy ? "Checking…" : "Unlock").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(LogColor.accent)
            .disabled(code.isEmpty)
            Button(letters ? "Use number pad" : "Use letters") {
                letters.toggle()
                focus = nil
                DispatchQueue.main.async { focus = .code }
            }
            .font(.subheadline)
            Button("Back") { switchTo(.choose) }.font(.subheadline).foregroundStyle(LogColor.ink2).padding(.top, 6)
        }
        .onAppear { focus = .code }
    }

    // MARK: Actions

    private func switchTo(_ m: Mode) {
        message = nil
        note = nil
        withAnimation(.snappy) { mode = m }
    }

    private func run(_ work: @escaping () async throws -> LogAuth.Result) {
        guard !busy else { return }
        busy = true
        message = nil
        note = nil
        Task {
            defer { busy = false }
            do {
                let result = try await work()
                if let err = await store.signIn(result) { message = err } else { password = "" }
            } catch {
                message = (error as? LogError)?.message ?? "That didn’t work. Try again."
            }
        }
    }

    private func submitEmail() {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password
        guard !e.isEmpty, !p.isEmpty else { return }
        let creating = mode == .create
        run { creating ? try await LogAuth.signUp(email: e, password: p) : try await LogAuth.signIn(email: e, password: p) }
    }

    private func submitPasscode() {
        guard !busy, !code.isEmpty else { return }
        busy = true
        message = nil
        Task {
            let ok = await store.unlock(code)
            busy = false
            if ok { code = "" }
        }
    }

    private func reset() {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { message = "Enter your email first."; return }
        busy = true
        Task {
            defer { busy = false }
            do { note = try await LogAuth.resetPassword(email: e); message = nil }
            catch { message = (error as? LogError)?.message ?? "Couldn’t send the email." }
        }
    }

    private func google() {
        run {
            let verifier = PKCE.verifier()
            let start = try await LogAuth.googleURL(codeChallenge: PKCE.challenge(verifier))
            let callback: URL
            do {
                callback = try await webAuth.authenticate(using: start, callbackURLScheme: LogAuth.callbackScheme,
                                                          preferredBrowserSession: .ephemeral)
            } catch {
                throw LogError.server("Google sign-in was cancelled.")
            }
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let desc = items.first(where: { $0.name == "error_description" })?.value {
                throw LogError.server(desc.replacingOccurrences(of: "+", with: " "))
            }
            guard let authCode = items.first(where: { $0.name == "code" })?.value else {
                throw LogError.server("Google didn’t finish signing in. Try again.")
            }
            return try await LogAuth.googleFinish(code: authCode, verifier: verifier)
        }
    }

    @State private var appleNonce = ""

    private func appleRequest(_ request: ASAuthorizationAppleIDRequest) {
        appleNonce = PKCE.verifier()
        request.requestedScopes = [.email]
        request.nonce = PKCE.sha256Hex(appleNonce)
    }

    private func appleDone(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            message = "Apple sign-in was cancelled."
            return
        }
        let nonce = appleNonce
        run { try await LogAuth.appleFinish(idToken: token, nonce: nonce) }
    }
}

/// Sign-in choices that depend on the app's setup.
public enum SignInOptions {
    /// Sign in with Apple needs the paid Apple developer program (and its capability). Off for now.
    public static let apple = false
}

/// PKCE for Google sign-in (RFC 7636).
enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(LogColor.surface, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
    }
}
