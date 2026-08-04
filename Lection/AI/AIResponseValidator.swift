import Foundation

enum AIResponseValidator {
    static func validate(
        article: GeneratedArticle,
        for request: ArticleGenerationRequest
    ) throws {
        var issues: [AIValidationIssue] = []

        guard request.minimumParagraphCount > 0,
              request.maximumParagraphCount >= request.minimumParagraphCount,
              request.minimumWordCount > 0,
              request.maximumWordCount >= request.minimumWordCount,
              request.preferredWordCountTolerance >= 0 else {
            throw AIProviderError.invalidRequest("文章长度或段落数量约束无效。")
        }
        if let preferredWordCount = request.preferredWordCount,
           !(request.minimumWordCount...request.maximumWordCount).contains(preferredWordCount) {
            throw AIProviderError.invalidRequest("文章目标词数必须处于允许范围内。")
        }

        if article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(code: .emptyTitle, path: "title"))
        }

        if !(request.minimumParagraphCount...request.maximumParagraphCount)
            .contains(article.paragraphs.count) {
            issues.append(.init(code: .paragraphCountOutOfRange, path: "paragraphs"))
        }

        let wordCount = EnglishWordCounter.count(in: article.paragraphs)
        if !(request.minimumWordCount...request.maximumWordCount).contains(wordCount) {
            issues.append(.init(code: .wordCountOutOfRange, path: "paragraphs.text"))
        }
        if let preferredWordCount = request.preferredWordCount,
           abs(wordCount - preferredWordCount) > request.preferredWordCountTolerance {
            issues.append(.init(code: .preferredWordCountMissed, path: "paragraphs.text"))
        }

        let duplicateParagraphIDs = duplicateValues(article.paragraphs.map(\.id))
        if !duplicateParagraphIDs.isEmpty {
            issues.append(.init(code: .duplicateParagraphID, path: "paragraphs.id"))
        }

        for (index, paragraph) in article.paragraphs.enumerated()
        where paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(code: .emptyParagraph, path: "paragraphs[\(index)].text"))
        }

        try throwIfNeeded(issues)
    }

    static func validate(
        questions: [GeneratedQuestion],
        for request: QuestionGenerationRequest
    ) throws {
        guard request.expectedQuestionCount > 0,
              !request.questionPlan.isEmpty,
              request.questionPlan.allSatisfy({
                  $0.count > 0
                      && !$0.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.difficulty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              request.questionPlan.reduce(0, { $0 + $1.count }) == request.expectedQuestionCount else {
            throw AIProviderError.invalidRequest("题目计划与题目数量约束无效。")
        }

        let sourceParagraphIDs = Set(request.sourceParagraphs.map(\.id))
        guard sourceParagraphIDs.count == request.sourceParagraphs.count else {
            throw AIProviderError.invalidRequest("原文段落 ID 不能重复。")
        }

        var issues: [AIValidationIssue] = []
        if questions.count != request.expectedQuestionCount {
            issues.append(.init(code: .questionCountMismatch, path: "questions"))
        }

        if !duplicateValues(questions.map(\.id)).isEmpty {
            issues.append(.init(code: .duplicateQuestionID, path: "questions.id"))
        }
        let allOptionIDs = questions.flatMap { $0.options.map(\.id) }
        if !duplicateValues(allOptionIDs).isEmpty {
            // QuestionOption 在 SwiftData 中全局唯一，因此跨题重复也必须在写入前拦截。
            issues.append(.init(code: .duplicateOptionID, path: "questions.options.id"))
        }

        var actualQuestionPlan: [QuestionPlanKey: Int] = [:]
        for (questionIndex, question) in questions.enumerated() {
            let questionPath = "questions[\(questionIndex)]"

            let category = question.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let difficulty = question.difficulty.trimmingCharacters(in: .whitespacesAndNewlines)
            if category.isEmpty {
                issues.append(.init(code: .emptyQuestionCategory, path: "\(questionPath).category"))
            }
            if difficulty.isEmpty {
                issues.append(.init(code: .emptyQuestionDifficulty, path: "\(questionPath).difficulty"))
            }
            if !category.isEmpty, !difficulty.isEmpty {
                actualQuestionPlan[.init(category: category, difficulty: difficulty), default: 0] += 1
            }
            if question.stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(code: .emptyQuestionStem, path: "\(questionPath).stem"))
            }
            if question.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(code: .emptyExplanation, path: "\(questionPath).explanation"))
            }
            if question.options.count != QuestionGenerationRequest.expectedOptionCount {
                issues.append(.init(code: .optionCountMismatch, path: "\(questionPath).options"))
            }
            let normalizedOptionTexts = question.options.map {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            if normalizedOptionTexts.contains("") {
                issues.append(.init(code: .emptyOption, path: "\(questionPath).options.text"))
            }
            if !duplicateValues(normalizedOptionTexts).isEmpty {
                issues.append(.init(code: .duplicateOptionText, path: "\(questionPath).options.text"))
            }
            if !question.options.contains(where: { $0.id == question.correctOptionID }) {
                issues.append(.init(code: .missingCorrectOption, path: "\(questionPath).correctOptionID"))
            }

            if question.evidenceParagraphIDs.isEmpty {
                issues.append(.init(code: .missingEvidence, path: "\(questionPath).evidenceParagraphIDs"))
            }
            if question.evidenceParagraphIDs.contains(where: { !sourceParagraphIDs.contains($0) }) {
                issues.append(.init(code: .unknownEvidenceParagraph, path: "\(questionPath).evidenceParagraphIDs"))
            }
        }

        let expectedQuestionPlan = request.questionPlan.reduce(into: [QuestionPlanKey: Int]()) {
            $0[.init(category: $1.category, difficulty: $1.difficulty), default: 0] += $1.count
        }
        if actualQuestionPlan != expectedQuestionPlan {
            issues.append(.init(code: .questionPlanMismatch, path: "questions.category"))
        }

        try throwIfNeeded(issues)
    }

    static func validate(
        translations: [ParagraphTranslation],
        for request: TranslationRequest
    ) throws {
        let expectedIDs = Set(request.sourceParagraphs.map(\.id))
        guard expectedIDs.count == request.sourceParagraphs.count else {
            throw AIProviderError.invalidRequest("待翻译段落 ID 不能重复。")
        }
        guard !request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidRequest("目标翻译语言不能为空。")
        }

        var issues: [AIValidationIssue] = []
        let returnedIDs = translations.map(\.paragraphID)
        let returnedIDSet = Set(returnedIDs)

        if returnedIDSet.count != returnedIDs.count {
            issues.append(.init(code: .duplicateTranslationParagraphID, path: "translations.paragraphID"))
        }
        if !expectedIDs.subtracting(returnedIDSet).isEmpty {
            issues.append(.init(code: .missingTranslation, path: "translations"))
        }
        if !returnedIDSet.subtracting(expectedIDs).isEmpty {
            issues.append(.init(code: .unknownTranslationParagraph, path: "translations.paragraphID"))
        }

        for (index, translation) in translations.enumerated()
        where translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(code: .emptyTranslation, path: "translations[\(index)].translatedText"))
        }

        try throwIfNeeded(issues)
    }

    private static func duplicateValues<Value: Hashable>(_ values: [Value]) -> Set<Value> {
        var seen: Set<Value> = []
        return values.reduce(into: Set<Value>()) { duplicates, value in
            if !seen.insert(value).inserted {
                duplicates.insert(value)
            }
        }
    }

    private static func throwIfNeeded(_ issues: [AIValidationIssue]) throws {
        if !issues.isEmpty {
            // 校验错误只保存字段路径和类别，不携带模型返回的正文。
            throw AIProviderError.validationFailed(issues)
        }
    }
}

private struct QuestionPlanKey: Hashable {
    let category: String
    let difficulty: String

    init(category: String, difficulty: String) {
        self.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        self.difficulty = difficulty.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum EnglishWordCounter {
    /// 只统计英文正文中的词，不把标题、标点或 CJK 文本误计入技能词数。
    static func count(in paragraphs: [GeneratedParagraph]) -> Int {
        paragraphs.reduce(0) { total, paragraph in
            let scalars = Array(paragraph.text.unicodeScalars)
            var count = 0
            var isInsideWord = false

            for index in scalars.indices {
                let scalar = scalars[index]
                if isASCIIEnglishLetter(scalar) {
                    if !isInsideWord {
                        count += 1
                    }
                    isInsideWord = true
                } else if isWordConnector(scalar),
                          isInsideWord,
                          nextScalar(after: index, in: scalars).map({ isASCIIEnglishLetter($0) }) ?? false {
                    // 保持 don't 和 well-known 为一个英文词；首尾标点不会启动新词。
                    continue
                } else {
                    isInsideWord = false
                }
            }
            return total + count
        }
    }

    private static func isASCIIEnglishLetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isWordConnector(_ scalar: UnicodeScalar) -> Bool {
        scalar == "'" || scalar == "\u{2019}" || scalar == "-"
    }

    private static func nextScalar(
        after index: [UnicodeScalar].Index,
        in scalars: [UnicodeScalar]
    ) -> UnicodeScalar? {
        let nextIndex = scalars.index(after: index)
        return nextIndex < scalars.endIndex ? scalars[nextIndex] : nil
    }
}
