import SwiftUI

private struct KeyboardDismissModifier<Field: Hashable>: ViewModifier {
    let focusedField: FocusState<Field?>.Binding

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        focusedField.wrappedValue = nil
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("收起键盘")
                    .help("收起键盘")
                }
            }
    }
}

extension View {
    func keyboardDismissible<Field: Hashable>(
        focusedField: FocusState<Field?>.Binding
    ) -> some View {
        modifier(KeyboardDismissModifier(focusedField: focusedField))
    }
}
