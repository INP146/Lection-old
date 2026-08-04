import SwiftUI

struct NewPracticeView: View {
    @State private var topic = ""
    @State private var articleLength = ArticleLength.medium

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
                }

                Section("篇幅") {
                    Picker("文章长度", selection: $articleLength) {
                        ForEach(ArticleLength.allCases) { length in
                            Text(length.title)
                                .tag(length)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("新建练习")
        }
    }
}

private enum ArticleLength: String, CaseIterable, Identifiable {
    case short
    case medium
    case long

    var id: Self { self }

    var title: String {
        switch self {
        case .short:
            "短"
        case .medium:
            "中"
        case .long:
            "长"
        }
    }
}

#Preview {
    NewPracticeView()
}
