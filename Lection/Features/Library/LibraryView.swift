import SwiftUI

struct LibraryView: View {
    let onCreate: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("还没有阅读材料", systemImage: "books.vertical")
            } actions: {
                Button("新建练习", systemImage: "plus", action: onCreate)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("资料库")
        }
    }
}

#Preview {
    LibraryView {}
}
