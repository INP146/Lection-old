import Foundation
import SwiftData
import Testing
@testable import Lection

@Suite("SwiftData persistence", .serialized)
@MainActor
struct PersistenceTests {
    @Test("Fixture survives reopening the persistent store")
    func fixtureSurvivesStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let storeURL = directory.appending(path: "Lection.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try makeDiskContainer(at: storeURL)
            container.mainContext.insert(PreviewFixtures.makeDocument())
            try container.mainContext.save()
        }

        do {
            let reopenedContainer = try makeDiskContainer(at: storeURL)
            let documents = try reopenedContainer.mainContext.fetch(FetchDescriptor<ReadingDocument>())

            #expect(documents.count == 1)
            let document = try #require(documents.first)
            #expect(document.title == "City Animals After Dark")
            #expect(document.state == .ready)
            #expect(document.paragraphs.count == 2)
            #expect(document.paragraphs.allSatisfy { $0.translatedText?.isEmpty == false })
            #expect(document.questions.count == 1)
            #expect(document.questions.first?.options.count == 3)
            #expect(document.processingJobs.first?.stage == .completed)
        }
    }

    @Test("Deleting a document cascades to every child model")
    func deletingDocumentCascadesToChildren() throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let document = PreviewFixtures.makeDocument()

        context.insert(document)
        try context.save()
        context.delete(document)
        try context.save()

        // 使用新 context 重新查询，避免已删除对象的内存状态掩盖 Store 中的残留数据。
        let verificationContext = ModelContext(container)
        #expect(try verificationContext.fetchCount(FetchDescriptor<ReadingDocument>()) == 0)
        #expect(try verificationContext.fetchCount(FetchDescriptor<Paragraph>()) == 0)
        #expect(try verificationContext.fetchCount(FetchDescriptor<Question>()) == 0)
        #expect(try verificationContext.fetchCount(FetchDescriptor<QuestionOption>()) == 0)
        #expect(try verificationContext.fetchCount(FetchDescriptor<ProcessingJob>()) == 0)
    }

    private func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: LectionSchema.schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: LectionSchema.schema,
            configurations: [configuration]
        )
    }
}
