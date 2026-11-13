import SwiftUI

struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var isMonospaced = true
    var trailingInset: CGFloat = 0

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(isMonospaced ? .callout.monospaced() : .callout)
        .autocorrectionDisabled()
        .padding(.leading, 10)
        .padding(.trailing, 10 + trailingInset)
        .frame(height: 30)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
    }
}
