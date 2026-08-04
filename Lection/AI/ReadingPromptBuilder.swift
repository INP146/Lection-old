import Foundation

enum ReadingPromptBuilderError: LocalizedError, Equatable, Sendable {
    case emptyTopic
    case unsupportedGenre(String)
    case preferredWordCountOutOfRange
    case emptySourceParagraphs
    case duplicateSourceParagraphID
    case emptySourceParagraph
    case emptyTargetLanguage
    case sourceEncodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyTopic:
            "阅读主题不能为空。"
        case let .unsupportedGenre(genre):
            "当前阅读技能不支持体裁：\(genre)。"
        case .preferredWordCountOutOfRange:
            "所选文章篇幅超出阅读技能允许范围。"
        case .emptySourceParagraphs:
            "原文段落不能为空。"
        case .duplicateSourceParagraphID:
            "原文段落 ID 不能重复。"
        case .emptySourceParagraph:
            "原文段落内容不能为空。"
        case .emptyTargetLanguage:
            "目标翻译语言不能为空。"
        case .sourceEncodingFailed:
            "无法编码原文段落。"
        }
    }
}

enum ArticlePromptBuilder {
    static func makeRequest(
        skill: ReadingSkill,
        topic: String,
        genre: String? = nil,
        preferredWordCount: Int? = nil
    ) throws -> ArticleGenerationRequest {
        let topic = topic.trimmed
        guard !topic.isEmpty else {
            throw ReadingPromptBuilderError.emptyTopic
        }

        let selectedGenre: String
        if let genre {
            let genre = genre.trimmed
            guard skill.supportedGenres.contains(where: {
                $0.caseInsensitiveCompare(genre) == .orderedSame
            }) else {
                throw ReadingPromptBuilderError.unsupportedGenre(genre)
            }
            selectedGenre = genre
        } else {
            selectedGenre = skill.supportedGenres.joined(separator: ", ")
        }

        if let preferredWordCount,
           !skill.targetWordCount.closedRange.contains(preferredWordCount) {
            throw ReadingPromptBuilderError.preferredWordCountOutOfRange
        }
        let lengthInstruction = preferredWordCount.map {
            "Aim for approximately \($0) English words while staying inside the required range."
        } ?? "Use any suitable length inside the required range."

        let prompt = AIRequestPrompt(
            system: """
            You create English reading passages from a versioned reading skill. Follow every skill constraint. Return only the structured article requested by the response schema.
            """,
            user: """
            Skill: \(skill.displayName) (id: \(skill.id), version: \(skill.version))
            Learning stage: \(skill.stage)
            Topic: \(topic)
            Genre: \(selectedGenre)

            Article constraints:
            - Write the title and article in English.
            - Target \(skill.targetWordCount.minimum)-\(skill.targetWordCount.maximum) English words.
            - \(lengthInstruction)
            - Produce \(skill.paragraphCount.minimum)-\(skill.paragraphCount.maximum) paragraphs.
            - Give every paragraph a unique UUID string in its `id` field. These IDs are stable references for later questions and translations.
            - Grammar requirements: \(list(skill.grammarRequirements))
            - Vocabulary target: \(skill.vocabularyConstraints.targetLevel).
            - At most \(ratioPercent(skill.vocabularyConstraints.maximumUnfamiliarWordRatio))% of words should be unfamiliar at that level.
            - Vocabulary requirements: \(list(skill.vocabularyConstraints.requirements))
            - Prohibited content: \(list(skill.prohibitedContent))
            - Additional skill instructions: \(skill.promptInstructions)

            Output fields must be `title` and `paragraphs`; every paragraph must contain only `id` and `text`.
            """
        )

        return ArticleGenerationRequest(
            prompt: prompt,
            minimumParagraphCount: skill.paragraphCount.minimum,
            maximumParagraphCount: skill.paragraphCount.maximum
        )
    }
}

enum QuestionPromptBuilder {
    static func makeRequest(
        skill: ReadingSkill,
        sourceParagraphs: [SourceParagraph]
    ) throws -> QuestionGenerationRequest {
        let sourceJSON = try encodedSourceParagraphs(sourceParagraphs)
        let plan = skill.questionPlan.map {
            "\($0.category): \($0.count) (difficulty: \($0.difficulty))"
        }.joined(separator: "; ")

        let prompt = AIRequestPrompt(
            system: """
            You create single-answer multiple-choice reading questions for a fixed English passage. Never alter or invent source paragraph IDs. Return only the structured questions requested by the response schema.
            """,
            user: """
            Skill: \(skill.displayName) (id: \(skill.id), version: \(skill.version))
            Create exactly \(skill.questionCount) questions.
            Question plan: \(plan)

            Requirements for every question:
            - Use a unique UUID string for the question `id` and for every option `id`.
            - Provide exactly four distinct answer options.
            - `correctOptionID` must exactly equal one of that question's option IDs.
            - Write `stem` and option text in English.
            - Write `explanation` in Simplified Chinese and explain why the correct option follows from the passage.
            - `evidenceParagraphIDs` must contain one or more unchanged `id` values from the source JSON below.
            - Do not use outside knowledge or add facts absent from the passage.
            - Distractor rules: \(list(skill.distractorRules))

            Source paragraphs (authoritative JSON):
            \(sourceJSON)

            Output must contain a top-level `questions` array.
            """
        )

        return QuestionGenerationRequest(
            prompt: prompt,
            sourceParagraphs: sourceParagraphs,
            expectedQuestionCount: skill.questionCount
        )
    }
}

enum TranslationPromptBuilder {
    static func makeRequest(
        sourceParagraphs: [SourceParagraph],
        targetLanguage: String = "zh-Hans"
    ) throws -> TranslationRequest {
        let targetLanguage = targetLanguage.trimmed
        guard !targetLanguage.isEmpty else {
            throw ReadingPromptBuilderError.emptyTargetLanguage
        }
        let sourceJSON = try encodedSourceParagraphs(sourceParagraphs)

        let prompt = AIRequestPrompt(
            system: """
            You translate a fixed English passage paragraph by paragraph. Preserve paragraph identity exactly and return only the structured translations requested by the response schema.
            """,
            user: """
            Translate every source paragraph into \(targetLanguage).

            Requirements:
            - Return exactly one translation for every source paragraph.
            - Copy each source `id` unchanged into `paragraphID`.
            - Do not omit, duplicate, merge, split, reorder, or invent paragraph IDs.
            - Preserve the original meaning and tone. Do not add explanations or notes.
            - Put only the translated paragraph text in `translatedText`.

            Source paragraphs (authoritative JSON):
            \(sourceJSON)

            Output must contain a top-level `translations` array.
            """
        )

        return TranslationRequest(
            prompt: prompt,
            sourceParagraphs: sourceParagraphs,
            targetLanguage: targetLanguage
        )
    }
}

private func encodedSourceParagraphs(_ paragraphs: [SourceParagraph]) throws -> String {
    guard !paragraphs.isEmpty else {
        throw ReadingPromptBuilderError.emptySourceParagraphs
    }
    guard Set(paragraphs.map(\.id)).count == paragraphs.count else {
        throw ReadingPromptBuilderError.duplicateSourceParagraphID
    }
    guard paragraphs.allSatisfy({ !$0.text.trimmed.isEmpty }) else {
        throw ReadingPromptBuilderError.emptySourceParagraph
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(paragraphs)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ReadingPromptBuilderError.sourceEncodingFailed
        }
        return json
    } catch let error as ReadingPromptBuilderError {
        throw error
    } catch {
        throw ReadingPromptBuilderError.sourceEncodingFailed
    }
}

private func list(_ values: [String]) -> String {
    values.isEmpty ? "none" : values.joined(separator: "; ")
}

private func ratioPercent(_ ratio: Double) -> String {
    (ratio * 100).formatted(.number.precision(.fractionLength(0...1)))
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
