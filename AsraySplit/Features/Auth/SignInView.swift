import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var sentTo: String?
    @State private var isWorking = false
    @State private var nonce = ""
    @State private var showEmail = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                AppMark(size: 88)
                VStack(spacing: 10) {
                    Text("Asray Split").font(.largeTitle.bold())
                    Text("Split trip costs fairly, keep every receipt, and settle up with the fewest payments.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    feature("receipt", "Scan receipts and assign items to people")
                    feature("wifi.slash", "Add expenses offline — they sync when you’re back")
                    feature("arrow.left.arrow.right", "See who owes whom, simplified")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    if app.env.backend.kind == .supabase {
                        SignInWithAppleButton(.continue) { request in
                            nonce = Self.randomNonce()
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = Self.sha256(nonce)
                        } onCompletion: { result in
                            Task { await handleApple(result) }
                        }
                        .signInWithAppleButtonStyle(.whiteOutline)
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        if let sentTo {
                            Label("Check \(sentTo) for a sign-in link.", systemImage: "envelope.badge")
                                .font(.subheadline).foregroundStyle(Color.brand)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if showEmail {
                            TextField("Email address", text: $email)
                                .textContentType(.emailAddress).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(14).background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
                            Button { Task { await sendLink() } } label: {
                                if isWorking { ProgressView() } else { Text("Email me a sign-in link") }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!email.contains("@") || isWorking)
                        } else {
                            Button("Continue with email") { showEmail = true }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    if app.env.demoBackend != nil {
                        Button {
                            Task { await app.enterDemoMode() }
                        } label: {
                            Text("Explore the demo trip")
                        }
                        .buttonStyle(app.env.backend.kind == .demo ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                        .accessibilityIdentifier("demoButton")
                        Text("Demo data stays on this iPhone and is never uploaded.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                LegalLinks()
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas.ignoresSafeArea())
    }

    private func feature(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).font(.subheadline) } icon: { Image(systemName: icon).foregroundStyle(Color.brand).frame(width: 28) }
    }

    private func sendLink() async {
        isWorking = true
        defer { isWorking = false }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await app.env.backend.auth.sendMagicLink(to: address)
            sentTo = address
        } catch {
            app.report(error)
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                app.presentedError = .unexpected(String(localized: "Apple didn’t return a sign-in token."))
                return
            }
            do { try await app.env.backend.auth.signInWithApple(idToken: token, nonce: nonce, fullName: credential.fullName) }
            catch { app.report(error) }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { app.report(error) }
        }
    }

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

@MainActor
struct LegalLinks: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 16) {
            Link("Privacy", destination: app.env.config.privacyURL)
            Link("Terms", destination: app.env.config.termsURL)
            Link("Support", destination: app.env.config.supportURL)
        }
        .font(.footnote)
    }
}

@MainActor
struct ProfileSetupView: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var emoji = "🧳"
    @State private var currency: CurrencyCode = CurrencyCode(Locale.current.currency?.identifier ?? "USD") ?? .usd
    @State private var saving = false
    private let emojis = ["🧳", "🌴", "🏔️", "🚲", "🎒", "🌮", "🎧", "⛵️"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name).textContentType(.name)
                } header: { Text("What should friends call you?") } footer: { Text("Shown to people in trips you join.") }
                Section("Avatar") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(emojis, id: \.self) { value in
                                Button(value) { emoji = value }
                                    .font(.title)
                                    .padding(8)
                                    .background(emoji == value ? Color.brand.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel(Text("Avatar \(value)"))
                                    .accessibilityAddTraits(emoji == value ? .isSelected : [])
                            }
                        }
                    }
                }
                Section("Home currency") {
                    CurrencyPicker(selection: $currency)
                }
            }
            .screenBackground()
            .navigationTitle("Welcome")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        Task { saving = true; await app.completeProfile(name: name.trimmingCharacters(in: .whitespaces), emoji: emoji, currency: currency); saving = false }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onAppear { if name.isEmpty { name = app.profile?.displayName ?? "" } }
        }
    }
}

@MainActor
struct CurrencyPicker: View {
    @Binding var selection: CurrencyCode
    var title: LocalizedStringKey = "Currency"

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Set(CurrencyCode.common + [selection])).sorted(), id: \.self) { code in
                Text("\(code.rawValue) – \(code.localizedName())").tag(code)
            }
        }
    }
}
