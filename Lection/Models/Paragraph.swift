import Foundation
import SwiftData

/// 阅读材料中的一个自然段。翻译与英文原文分开保存，便于单段显示和局部重试。
@Model
final class Paragraph {
    @Attribute(.unique) var id: UUID
    var order: Int
    var originalText: String
    var translatedText: String?
    var translationLanguage: String?
    var translationModel: String?

    var document: ReadingDocument?

    init(
        id: UUID = UUID(),
        order: Int,
        originalText: String,
        translatedText: String? = nil,
        translationLanguage: String? = nil,
        translationModel: String? = nil
    ) {
        self.id = id
        self.order = order
        self.originalText = originalText
        self.translatedText = translatedText
        self.translationLanguage = translationLanguage
        self.translationModel = translationModel
    }
}
