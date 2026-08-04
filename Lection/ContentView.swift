import SwiftUI

struct ContentView: View {
    @State private var selectedTab = AppTab.library
    @State private var generationCoordinator = GenerationCoordinator()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("资料库", systemImage: "books.vertical", value: .library) {
                LibraryView(
                    coordinator: generationCoordinator,
                    onCreate: { selectedTab = .create },
                    onOpenSettings: { selectedTab = .settings }
                )
            }

            Tab("新建", systemImage: "plus", value: .create) {
                NewPracticeView(
                    coordinator: generationCoordinator,
                    onOpenSettings: { selectedTab = .settings }
                )
            }

            Tab("设置", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
    }
}

private enum AppTab: Hashable {
    case library
    case create
    case settings
}

#Preview {
    ContentView()
}
