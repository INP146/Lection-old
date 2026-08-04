import SwiftUI

struct ContentView: View {
    @State private var selectedTab = AppTab.library

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("资料库", systemImage: "books.vertical", value: .library) {
                LibraryView {
                    selectedTab = .create
                }
            }

            Tab("新建", systemImage: "plus", value: .create) {
                NewPracticeView()
            }

            Tab("设置", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    Color.clear
                        .navigationTitle("设置")
                }
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
