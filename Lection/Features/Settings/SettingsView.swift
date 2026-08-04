import SwiftUI

struct SettingsView: View {
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var isAPIKeyVisible = false

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("模型名称", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("API Key") {
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField("API Key", text: $apiKey)
                            } else {
                                SecureField("API Key", text: $apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()

                        Button {
                            isAPIKeyVisible.toggle()
                        } label: {
                            Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key")
                        .help(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

#Preview {
    SettingsView()
}
