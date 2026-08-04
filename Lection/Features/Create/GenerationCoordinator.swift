import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class GenerationCoordinator {
    enum Phase: Equatable {
        case idle
        case preparing
        case running
        case completed
        case failed
        case cancelled
    }

    private(set) var phase: Phase = .idle
    private(set) var stage: ProcessingStage?
    private(set) var activeJobID: UUID?
    private(set) var document: ReadingDocument?
    private(set) var message: String?

    @ObservationIgnored
    private var operationTask: Task<Void, Never>?
    @ObservationIgnored
    private let configurationStore: any ProviderConfigurationPersisting
    @ObservationIgnored
    private let keychainStore: any APIKeyStoring

    init(
        configurationStore: any ProviderConfigurationPersisting = UserDefaultsProviderConfigurationStore(),
        keychainStore: any APIKeyStoring = KeychainStore.apiKey
    ) {
        self.configurationStore = configurationStore
        self.keychainStore = keychainStore
    }

    var isRunning: Bool {
        phase == .preparing || phase == .running
    }

    func isRunning(_ job: ProcessingJob) -> Bool {
        isRunning && activeJobID == job.id
    }

    func providerConfigurationIssue() -> String? {
        let configuration = configurationStore.load()
        guard !configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请先配置模型名称。"
        }

        do {
            guard let apiKey = try keychainStore.loadAPIKey(),
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "请先保存 API Key。"
            }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    func start(
        request: ReadingGenerationRequest,
        modelContext: ModelContext
    ) {
        launch(modelContext: modelContext) { pipeline in
            try await pipeline.start(request)
        }
    }

    func resume(_ job: ProcessingJob, modelContext: ModelContext) {
        launch(job: job, modelContext: modelContext) { pipeline in
            try await pipeline.resume(job)
        }
    }

    func retry(_ job: ProcessingJob, modelContext: ModelContext) {
        launch(job: job, modelContext: modelContext) { pipeline in
            try await pipeline.retry(job)
        }
    }

    func cancel() {
        operationTask?.cancel()
    }

    func resetResult() {
        guard !isRunning else { return }
        phase = .idle
        stage = nil
        activeJobID = nil
        document = nil
        message = nil
    }

    private func launch(
        job: ProcessingJob? = nil,
        modelContext: ModelContext,
        operation: @escaping @MainActor (GenerationPipeline) async throws -> ReadingDocument
    ) {
        guard !isRunning else { return }

        phase = .preparing
        stage = job?.stage
        activeJobID = job?.id
        document = job?.document
        message = nil

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { operationTask = nil }

            do {
                let provider = try makeProvider()
                let pipeline = GenerationPipeline(
                    modelContext: modelContext,
                    provider: provider,
                    executionModelName: provider.modelName
                ) { [weak self] job in
                    self?.receiveProgress(from: job)
                }
                let finishedDocument = try await operation(pipeline)
                document = finishedDocument
                stage = .completed
                phase = .completed
                message = nil
            } catch is CancellationError {
                phase = .cancelled
                message = "生成已取消，草稿已保留。"
            } catch {
                phase = .failed
                message = document?.processingJobs
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .first?.lastError ?? error.localizedDescription
            }
        }
    }

    private func receiveProgress(from job: ProcessingJob) {
        activeJobID = job.id
        document = job.document
        stage = job.stage
        message = job.lastError

        switch job.stage {
        case .completed:
            phase = .completed
        case .failed:
            phase = .failed
        case .cancelled:
            phase = .cancelled
        default:
            phase = .running
        }
    }

    private func makeProvider() throws -> OpenAICompatibleProvider {
        let storedConfiguration = configurationStore.load()
        let configuration = try ProviderConfiguration.validated(
            baseURLText: storedConfiguration.baseURL.absoluteString,
            modelName: storedConfiguration.modelName,
            requestTimeout: storedConfiguration.requestTimeout,
            supportsJSONSchema: storedConfiguration.supportsJSONSchema,
            supportsJSONObject: storedConfiguration.supportsJSONObject
        )
        guard let apiKey = try keychainStore.loadAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainStoreError.invalidAPIKey
        }
        return OpenAICompatibleProvider(configuration: configuration, apiKey: apiKey)
    }
}

extension ProcessingStage {
    var displayTitle: String {
        switch self {
        case .extracting: "提取内容"
        case .classifying: "识别类型"
        case .structuring: "整理结构"
        case .generatingArticle: "生成文章"
        case .generatingQuestions: "生成题目"
        case .translating: "翻译段落"
        case .validating: "检查内容"
        case .completed: "生成完成"
        case .cancelled: "已取消"
        case .failed: "生成失败"
        }
    }

    var progressValue: Double {
        switch self {
        case .generatingArticle: 0.12
        case .generatingQuestions: 0.4
        case .translating: 0.68
        case .validating: 0.9
        case .completed: 1
        default: 0
        }
    }
}
