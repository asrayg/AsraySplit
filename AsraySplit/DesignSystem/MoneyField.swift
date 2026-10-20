import SwiftUI

/// Text field that edits an exact `Money` value. Text is parsed with the user's locale into minor
/// units; invalid text is shown but never converted through floating point.
@MainActor
struct MoneyField: View {
    let title: LocalizedStringKey
    @Binding var minorUnits: Int64?
    let currency: CurrencyCode
    var allowNegative = false
    var font: Font = .body

    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var focused: Bool
    private let parser = MoneyParser()

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(currency.fractionDigits == 0 ? .numberPad : .decimalPad)
            .font(font.monospacedDigit())
            .focused($focused)
            .foregroundStyle(isInvalid ? Color.negative : Color.primary)
            .onAppear { syncText() }
            .onChange(of: minorUnits) { _, _ in if !focused { syncText() } }
            .onChange(of: currency) { _, _ in parse() }
            .onChange(of: text) { _, _ in parse() }
            .accessibilityValue(minorUnits.map { Money(minorUnits: $0, currency: currency).formatted() } ?? "")
    }

    private func syncText() {
        text = minorUnits.map { parser.editableString(for: Money(minorUnits: $0, currency: currency)) } ?? ""
    }

    private func parse() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            isInvalid = false
            if minorUnits != nil { minorUnits = nil }
            return
        }
        if let money = try? parser.parse(text, currency: currency, allowNegative: allowNegative) {
            isInvalid = false
            if minorUnits != money.minorUnits { minorUnits = money.minorUnits }
        } else {
            isInvalid = true
        }
    }
}

/// Edits a decimal (percent, share weight, exchange rate) without floating point.
@MainActor
struct DecimalField: View {
    let title: LocalizedStringKey
    @Binding var value: Decimal?
    var maxFractionDigits = 4

    @State private var text = ""
    @FocusState private var focused: Bool
    private let parser = MoneyParser()

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = value.map { NSDecimalNumber(decimal: $0).description(withLocale: Locale.current) } ?? "" }
            .onChange(of: value) { _, newValue in
                if !focused { text = newValue.map { NSDecimalNumber(decimal: $0).description(withLocale: Locale.current) } ?? "" }
            }
            .onChange(of: text) { _, newText in
                guard !newText.isEmpty, let parsed = try? parser.parseDecimal(newText), parsed >= 0 else { value = nil; return }
                var input = parsed
                var rounded = Decimal()
                NSDecimalRound(&rounded, &input, maxFractionDigits, .plain)
                value = rounded
            }
    }
}
