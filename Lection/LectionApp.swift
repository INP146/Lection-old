import SwiftUI
import SwiftData

@main
struct LectionApp: App {
    private let modelContainer: ModelContainer = {
        do {
            let container = try LectionSchema.makeContainer()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-LectionPreviewFixtures"),
               try container.mainContext.fetchCount(FetchDescriptor<ReadingDocument>()) == 0 {
                // 仅供模拟器 UI 检查使用；普通 Debug 启动也不会写入示例内容。
                container.mainContext.insert(PreviewFixtures.makeDocument())
                try container.mainContext.save()
            }
#endif
            return container
        } catch {
            // 数据容器不可用时继续运行只会造成内容悄然丢失，因此在启动阶段明确失败。
            fatalError("无法创建本地数据容器：\(error.localizedDescription)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
