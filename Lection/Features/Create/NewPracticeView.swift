import SwiftData
import SwiftUI

struct NewPracticeView: View {
    let coordinator: GenerationCoordinator
    let onOpenSettings: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var topic = ""
    @State private var articleLength = ArticleLength.medium
    @State private var providerIssue: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    LabeledContent("阅读技能", value: "通用英语阅读")

                    TextField(
                        "主题，例如：城市里的夜间动物",
                        text: $topic,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .disabled(coordinator.isRunning)
                }

                Section("篇幅") {
                    Picker("文章长度", selection: $articleLength) {
                        ForEach(ArticleLength.allCases) { length in
                            Text(length.title)
                                .tag(length)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(coordinator.isRunning)

                    LabeledContent("目标词数", value: "约 \(articleLength.targetWordCount) 词")
                        .foregroundStyle(.secondary)
                }

                if let providerIssue {
                    Section {
                        Label(providerIssue, systemImage: "key.slash")
                            .foregroundStyle(.orange)

                        Button("前往设置", systemImage: "gearshape", action: onOpenSettings)
                    }
                }

                generationSection
            }
            .navigationTitle("新建练习")
            .onAppear(perform: refreshProviderStatus)
            .onChange(of: coordinator.phase) {
                refreshProviderStatus()
            }
        }
    }

    @ViewBuilder
    private var generationSection: some View {
        Section {
            switch coordinator.phase {
            case .preparing, .running:
                GenerationProgressContent(
                    stage: coordinator.stage,
                    onCancel: coordinator.cancel
                )
            case .failed, .cancelled:
                if let message = coordinator.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if let document = coordinator.document {
                    NavigationLink {
                        DocumentDestinationView(
                            document: document,
                            coordinator: coordinator,
                            onOpenSettings: onOpenSettings
                        )
                    } label: {
                        Label("查看并继续", systemImage: "arrow.clockwise")
                    }
                }
                generateButton
            case .completed:
                if let document = coordinator.document {
                    Label("阅读练习已生成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    NavigationLink {
                        ReadingPracticeView(document: document)
                    } label: {
                        Label("开始阅读", systemImage: "book.pages")
                    }
                }
                Button("新建另一篇", systemImage: "plus") {
                    topic = ""
                    coordinator.resetResult()
                }
            case .idle:
                generateButton
            }
        }
    }

    private var generateButton: some View {
        Button {
            startGeneration()
        } label: {
            Label("开始生成", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .disabled(
            topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || providerIssue != nil
                || coordinator.isRunning
        )
    }

    private func startGeneration() {
        do {
            let skill = try ReadingSkillLoader().loadBuiltInSkill()
            let configuration = UserDefaultsProviderConfigurationStore().load()
            let request = ReadingGenerationRequest(
                topic: topic,
                genre: "expository",
                targetLanguage: "zh-Hans",
                translationModel: configuration.modelName,
                targetWordCount: articleLength.targetWordCount,
                skill: skill
            )
            coordinator.start(request: request, modelContext: modelContext)
        } catch {
            providerIssue = error.localizedDescription
        }
    }

    private func refreshProviderStatus() {
        providerIssue = coordinator.providerConfigurationIssue()
    }
}

struct GenerationProgressContent: View {
    let stage: ProcessingStage?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(stage?.displayTitle ?? "准备模型请求")
                Spacer()
                Text(stage?.progressValue.formatted(.percent.precision(.fractionLength(0))) ?? "")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: stage?.progressValue ?? 0.02)

            Button("取消生成", systemImage: "xmark", role: .cancel, action: onCancel)
        }
        .padding(.vertical, 4)
    }
}

private enum ArticleLength: String, CaseIterable, Identifiable {
    case short
    case medium
    case long

    var id: Self { self }

    var title: String {
        switch self {
        case .short: "短"
        case .medium: "中"
        case .long: "长"
        }
    }

    var targetWordCount: Int {
        switch self {
        case .short: 375
        case .medium: 425
        case .long: 475
        }
    }
}

#Preview {
    NewPracticeView(coordinator: GenerationCoordinator()) {}
        .modelContainer(PreviewFixtures.makeContainer())
}
