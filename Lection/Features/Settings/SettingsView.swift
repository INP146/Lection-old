import SwiftUI

struct SettingsView: View {
    @State private var settings = ProviderSettings()
    @State private var isAPIKeyVisible = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("模型服务") {
                    TextField("Base URL", text: $settings.baseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("模型名称", text: $settings.modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Stepper(value: $settings.requestTimeout, in: 15...180, step: 15) {
                        LabeledContent("请求超时", value: "\(Int(settings.requestTimeout)) 秒")
                    }
                }

                Section("结构化输出") {
                    Toggle("JSON Schema", isOn: $settings.supportsJSONSchema)
                    Toggle("JSON Object", isOn: $settings.supportsJSONObject)
                }

                Section("API Key") {
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField(apiKeyPlaceholder, text: $settings.apiKeyInput)
                            } else {
                                SecureField(apiKeyPlaceholder, text: $settings.apiKeyInput)
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

                    if settings.hasSavedAPIKey {
                        Button(role: .destructive) {
                            isDeleteConfirmationPresented = true
                        } label: {
                            Label("删除已保存的 API Key", systemImage: "trash")
                        }
                    }
                }

                Section {
                    Button {
                        settings.save()
                    } label: {
                        Label("保存配置", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        Task { await settings.testConnection() }
                    } label: {
                        Label("测试连接", systemImage: "network")
                    }

                    operationStatus
                }
                .disabled(settings.isBusy)
            }
            .navigationTitle("设置")
            .alert("删除 API Key？", isPresented: $isDeleteConfirmationPresented) {
                Button("删除", role: .destructive) {
                    settings.deleteAPIKey()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var apiKeyPlaceholder: String {
        settings.hasSavedAPIKey ? "输入新密钥以替换" : "API Key"
    }

    @ViewBuilder
    private var operationStatus: some View {
        switch settings.operation {
        case .idle:
            EmptyView()
        case .saving:
            Label("正在保存…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.secondary)
        case .testing:
            HStack {
                ProgressView()
                Text("正在测试连接…")
                    .foregroundStyle(.secondary)
            }
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    SettingsView()
}
