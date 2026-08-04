import SwiftUI
import SwiftData

struct LibraryView: View {
    let onCreate: () -> Void

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
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(documents) { document in
                        DocumentRow(document: document)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("资料库")
        }
    }
}

#Preview {
    LibraryView {}
        .modelContainer(PreviewFixtures.makeContainer())
}

private struct DocumentRow: View {
    let document: ReadingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title)
                .font(.headline)

            HStack(spacing: 12) {
                Label(document.state.title, systemImage: document.state.systemImage)
                    .foregroundStyle(document.state.tint)

                Text("\(document.paragraphs.count) 段")
                Text("\(document.questions.count) 题")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
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
