import Foundation

enum AIResponseValidator {
    static func validate(
        article: GeneratedArticle,
        for request: ArticleGenerationRequest
    ) throws {
        var issues: [AIValidationIssue] = []

        guard request.minimumParagraphCount > 0,
              request.maximumParagraphCount >= request.minimumParagraphCount else {
            throw AIProviderError.invalidRequest("文章段落数量约束无效。")
        }

        if article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(code: .emptyTitle, path: "title"))
        }

        if !(request.minimumParagraphCount...request.maximumParagraphCount)
            .contains(article.paragraphs.count) {
            issues.append(.init(code: .paragraphCountOutOfRange, path: "paragraphs"))
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
        guard request.expectedQuestionCount > 0 else {
            throw AIProviderError.invalidRequest("题目数量必须大于零。")
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

        for (questionIndex, question) in questions.enumerated() {
            let questionPath = "questions[\(questionIndex)]"

            if question.stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(code: .emptyQuestionStem, path: "\(questionPath).stem"))
            }
            if question.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(code: .emptyExplanation, path: "\(questionPath).explanation"))
            }
            if question.options.count < 3 {
                issues.append(.init(code: .insufficientOptions, path: "\(questionPath).options"))
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
