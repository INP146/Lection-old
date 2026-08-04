import SwiftUI
import SwiftData

@main
struct LectionApp: App {
    private let modelContainer: ModelContainer = {
        do {
            return try LectionSchema.makeContainer()
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
