import SwiftData
import SwiftUI

struct LibraryView: View {
    let coordinator: GenerationCoordinator
    let onCreate: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReadingDocument.updatedAt, order: .reverse)
    private var documents: [ReadingDocument]

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    ContentUnavailableView {
                        Label("还没有阅读材料", systemImage: "books.vertical")
                    } actions: {
                        Button("新建练习", systemImage: "plus", action: onCreate)
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    List {
                        ForEach(documents) { document in
                            NavigationLink {
                                DocumentDestinationView(
                                    document: document,
                                    coordinator: coordinator,
                                    onOpenSettings: onOpenSettings
                                )
                            } label: {
                                DocumentRow(document: document)
                            }
                        }
                        .onDelete(perform: deleteDocuments)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("资料库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("新建练习", systemImage: "plus", action: onCreate)
                }
            }
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for index in offsets {
            let document = documents[index]
            guard !document.processingJobs.contains(where: coordinator.isRunning) else {
                continue
            }
            modelContext.delete(document)
        }
        try? modelContext.save()
    }
}

struct DocumentDestinationView: View {
    let document: ReadingDocument
    let coordinator: GenerationCoordinator
    let onOpenSettings: () -> Void

    var body: some View {
        if document.state == .ready {
            ReadingPracticeView(document: document)
        } else {
            ProcessingDocumentView(
                document: document,
                coordinator: coordinator,
                onOpenSettings: onOpenSettings
            )
        }
    }
}

private struct ProcessingDocumentView: View {
    let document: ReadingDocument
    let coordinator: GenerationCoordinator
    let onOpenSettings: () -> Void

    @Environment(\.modelContext) private var modelContext

    private var latestJob: ProcessingJob? {
        document.processingJobs.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    var body: some View {
        List {
            Section("当前状态") {
                if let job = latestJob {
                    Label(job.stage.displayTitle, systemImage: statusSymbol(for: job.stage))
                        .foregroundStyle(statusColor(for: job.stage))

                    if coordinator.isRunning(job) {
                        GenerationProgressContent(
                            stage: coordinator.stage ?? job.stage,
                            onCancel: coordinator.cancel
                        )
                    } else if let error = job.lastError {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("任务数据缺失", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section("已保存") {
                LabeledContent("英文段落", value: "\(document.paragraphs.count)")
                LabeledContent("阅读题", value: "\(document.questions.count)")
                LabeledContent(
                    "译文",
                    value: "\(document.paragraphs.filter { $0.translatedText != nil }.count) / \(document.paragraphs.count)"
                )
            }

            if shouldShowActionSection {
                Section {
                    actionContent
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var actionContent: some View {
        if let job = latestJob {
            if coordinator.isRunning {
                Label("另一项生成任务正在运行", systemImage: "clock")
                    .foregroundStyle(.secondary)
            } else if let issue = coordinator.providerConfigurationIssue() {
                Label(issue, systemImage: "key.slash")
                    .foregroundStyle(.orange)
                Button("前往设置", systemImage: "gearshape", action: onOpenSettings)
            } else if job.stage == .failed || job.stage == .cancelled {
                Button("从失败步骤重试", systemImage: "arrow.clockwise") {
                    coordinator.retry(job, modelContext: modelContext)
                }
                .buttonStyle(.glassProminent)
            } else if job.stage != .completed {
                Button("继续生成", systemImage: "play.fill") {
                    coordinator.resume(job, modelContext: modelContext)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var shouldShowActionSection: Bool {
        guard let job = latestJob else { return true }
        return !coordinator.isRunning(job)
    }

    private func statusSymbol(for stage: ProcessingStage) -> String {
        switch stage {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "pause.circle.fill"
        default: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }

    private func statusColor(for stage: ProcessingStage) -> Color {
        switch stage {
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        default: .blue
        }
    }
}

private struct DocumentRow: View {
    let document: ReadingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(
                    rowStatusTitle,
                    systemImage: document.state.systemImage
                )
                .foregroundStyle(document.state.tint)

                Text("\(document.paragraphs.count) 段")
                Text("\(document.questions.count) 题")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var rowStatusTitle: String {
        guard let job = document.processingJobs.sorted(by: { $0.updatedAt > $1.updatedAt }).first else {
            return document.state.title
        }
        if job.stage == .failed, let failedStage = job.failedStage {
            return "\(failedStage.displayTitle)失败"
        }
        if job.stage == .cancelled, let failedStage = job.failedStage {
            return "已暂停 · \(failedStage.displayTitle)"
        }
        return job.stage.displayTitle
    }
}

private extension DocumentState {
    var title: String {
        switch self {
        case .draft: "草稿"
        case .processing: "处理中"
        case .ready: "可阅读"
        case .failed: "处理失败"
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "doc"
        case .processing: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .draft: .secondary
        case .processing: .blue
        case .ready: .green
        case .failed: .red
        }
    }
}

#Preview {
    LibraryView(coordinator: GenerationCoordinator(), onCreate: {}, onOpenSettings: {})
        .modelContainer(PreviewFixtures.makeContainer())
}
