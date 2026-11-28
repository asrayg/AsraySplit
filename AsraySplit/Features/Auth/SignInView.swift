import SwiftUI

/// "Who are you?" — the crew build has no email or password. Tapping a name creates an anonymous
/// Supabase account on this iPhone and names it; row-level security still scopes data to trip members.
@MainActor
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var working: CrewMember?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                AppMark(size: 88)
                VStack(spacing: 10) {
                    Text("Who are you?").font(.largeTitle.bold())
                }
                Group {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(CrewMember.all) { member in
                            Button { Task { await pick(member) } } label: {
                                VStack(spacing: 8) {
                                    if working == member { ProgressView().frame(height: 44) }
                                    else { Text(member.emoji).font(.system(size: 40)) }
                                    Text(member.name).font(.headline)
                                }
                                .frame(maxWidth: .infinity, minHeight: 110)
                                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(working != nil)
                            .accessibilityIdentifier("crew-\(member.name)")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas.ignoresSafeArea())
    }

    private func pick(_ member: CrewMember) async {
        working = member
        await app.signIn(as: member)
        working = nil
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
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
