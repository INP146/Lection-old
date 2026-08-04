import SwiftData
import SwiftUI

struct ReadingPracticeView: View {
    @Bindable var document: ReadingDocument
    @State private var mode = PracticeMode.reading
    @State private var visibleTranslationIDs: Set<UUID> = []
    @State private var evidenceParagraphIDs: [UUID] = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("练习内容", selection: $mode) {
                ForEach(PracticeMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            switch mode {
            case .reading:
                ReadingPane(
                    document: document,
                    visibleTranslationIDs: $visibleTranslationIDs,
                    evidenceParagraphIDs: $evidenceParagraphIDs
                )
            case .questions:
                QuizPane(document: document) { paragraphIDs in
                    evidenceParagraphIDs = paragraphIDs
                    mode = .reading
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum PracticeMode: String, CaseIterable, Identifiable {
    case reading
    case questions

    var id: Self { self }

    var title: String {
        switch self {
        case .reading: "阅读"
        case .questions: "答题"
        }
    }

    var systemImage: String {
        switch self {
        case .reading: "book.pages"
        case .questions: "checklist"
        }
    }
}

private struct ReadingPane: View {
    let document: ReadingDocument
    @Binding var visibleTranslationIDs: Set<UUID>
    @Binding var evidenceParagraphIDs: [UUID]

    private var paragraphs: [Paragraph] {
        document.paragraphs.sorted { $0.order < $1.order }
    }

    private var isShowingAllTranslations: Bool {
        !paragraphs.isEmpty && paragraphs.allSatisfy { visibleTranslationIDs.contains($0.id) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs) { paragraph in
                        ParagraphView(
                            paragraph: paragraph,
                            isTranslationVisible: visibleTranslationIDs.contains(paragraph.id),
                            isEvidence: evidenceParagraphIDs.contains(paragraph.id)
                        ) {
                            if visibleTranslationIDs.contains(paragraph.id) {
                                visibleTranslationIDs.remove(paragraph.id)
                            } else {
                                visibleTranslationIDs.insert(paragraph.id)
                            }
                        }
                        .id(paragraph.id)

                        if paragraph.id != paragraphs.last?.id {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 28)
            }
            .onChange(of: evidenceParagraphIDs) {
                guard let firstID = evidenceParagraphIDs.first else { return }
                withAnimation(.easeInOut) {
                    proxy.scrollTo(firstID, anchor: .top)
                }
            }
            .onAppear {
                guard let firstID = evidenceParagraphIDs.first else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(firstID, anchor: .top)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if isShowingAllTranslations {
                        visibleTranslationIDs.removeAll()
                    } else {
                        visibleTranslationIDs = Set(paragraphs.map(\.id))
                    }
                } label: {
                    Image(systemName: isShowingAllTranslations ? "character.book.closed.fill" : "character.book.closed")
                }
                .accessibilityLabel(isShowingAllTranslations ? "隐藏全部翻译" : "显示全部翻译")
                .help(isShowingAllTranslations ? "隐藏全部翻译" : "显示全部翻译")
                .disabled(paragraphs.allSatisfy { $0.translatedText == nil })
            }
        }
    }
}

private struct ParagraphView: View {
    let paragraph: Paragraph
    let isTranslationVisible: Bool
    let isEvidence: Bool
    let onToggleTranslation: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(paragraph.order + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 12) {
                if isEvidence {
                    Label("原文证据", systemImage: "text.quote")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Text(paragraph.originalText)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isTranslationVisible, let translation = paragraph.translatedText {
                    Text(translation)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Button(action: onToggleTranslation) {
                Image(systemName: isTranslationVisible ? "eye.slash" : "character.book.closed")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isTranslationVisible ? "隐藏本段翻译" : "显示本段翻译")
            .help(isTranslationVisible ? "隐藏本段翻译" : "显示本段翻译")
            .disabled(paragraph.translatedText == nil)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .background(
            isEvidence ? Color.orange.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .animation(.easeInOut, value: isTranslationVisible)
    }
}

private struct QuizPane: View {
    let document: ReadingDocument
    let onShowEvidence: ([UUID]) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var saveError: String?

    private var questions: [Question] {
        document.questions.sorted { $0.order < $1.order }
    }

    private var isSubmitted: Bool {
        !questions.isEmpty && questions.allSatisfy { $0.answeredAt != nil }
    }

    private var canSubmit: Bool {
        !questions.isEmpty && questions.allSatisfy { $0.selectedOptionID != nil }
    }

    private var correctCount: Int {
        questions.filter { $0.isCorrect == true }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isSubmitted {
                    scoreHeader
                }

                ForEach(questions) { question in
                    QuestionView(
                        question: question,
                        isSubmitted: isSubmitted,
                        evidenceParagraphs: evidenceParagraphs(for: question),
                        onSelect: saveSelection,
                        onShowEvidence: { onShowEvidence(question.evidenceParagraphIDs) }
                    )

                    if question.id != questions.last?.id {
                        Divider()
                    }
                }

                if !isSubmitted {
                    Button {
                        submitQuiz()
                    } label: {
                        Label("提交答案", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .padding(.vertical, 24)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
        .alert("无法保存答题结果", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var scoreHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("答题结果")
                    .font(.headline)
                Text("已提交 \(questions.count) 道题")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(correctCount) / \(questions.count)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(correctCount == questions.count ? .green : .primary)
        }
        .padding(.vertical, 20)
    }

    private func evidenceParagraphs(for question: Question) -> [Paragraph] {
        let evidenceIDs = Set(question.evidenceParagraphIDs)
        return document.paragraphs
            .filter { evidenceIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
    }

    private func saveSelection() {
        do {
            document.updatedAt = .now
            try modelContext.save()
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
        }
    }

    private func submitQuiz() {
        let submittedAt = Date.now
        for question in questions {
            question.answeredAt = submittedAt
        }
        do {
            document.updatedAt = submittedAt
            try modelContext.save()
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
        }
    }
}

private struct QuestionView: View {
    @Bindable var question: Question
    let isSubmitted: Bool
    let evidenceParagraphs: [Paragraph]
    let onSelect: () -> Void
    let onShowEvidence: () -> Void

    private var options: [QuestionOption] {
        question.options.sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第 \(question.order + 1) 题")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(question.stem)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(options) { option in
                    Button {
                        question.selectedOptionID = option.id
                        onSelect()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: optionSymbol(option))
                                .foregroundStyle(optionColor(option))
                                .frame(width: 22)
                            Text(option.text)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(optionBackground(option), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitted)
                }
            }

            if isSubmitted {
                Label(
                    question.isCorrect == true ? "回答正确" : "回答错误",
                    systemImage: question.isCorrect == true ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(question.isCorrect == true ? .green : .red)
                .font(.subheadline.weight(.semibold))

                Text(question.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !evidenceParagraphs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("原文证据", systemImage: "text.quote")
                            .font(.subheadline.weight(.semibold))
                        ForEach(evidenceParagraphs) { paragraph in
                            Text(paragraph.originalText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("定位到原文", systemImage: "arrow.up.forward") {
                            onShowEvidence()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 22)
    }

    private func optionSymbol(_ option: QuestionOption) -> String {
        if isSubmitted, option.id == question.correctOptionID {
            return "checkmark.circle.fill"
        }
        if isSubmitted, option.id == question.selectedOptionID {
            return "xmark.circle.fill"
        }
        return option.id == question.selectedOptionID ? "checkmark.circle.fill" : "circle"
    }

    private func optionColor(_ option: QuestionOption) -> Color {
        if isSubmitted, option.id == question.correctOptionID {
            return .green
        }
        if isSubmitted, option.id == question.selectedOptionID {
            return .red
        }
        return option.id == question.selectedOptionID ? .accentColor : .secondary
    }

    private func optionBackground(_ option: QuestionOption) -> Color {
        if isSubmitted, option.id == question.correctOptionID {
            return .green.opacity(0.1)
        }
        if isSubmitted, option.id == question.selectedOptionID {
            return .red.opacity(0.1)
        }
        return option.id == question.selectedOptionID ? .accentColor.opacity(0.1) : .clear
    }
}

#Preview {
    NavigationStack {
        ReadingPracticeView(document: PreviewFixtures.makeDocument())
    }
    .modelContainer(PreviewFixtures.makeContainer())
}
