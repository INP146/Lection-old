# AI 英语阅读练习 App 设计文档

> 文档状态：初稿  
> 目标平台：iOS  
> 产品形态：无自有服务端、本地优先、用户自备模型 API Key（BYOK）

## 1. 产品概述

本产品是一款由 AI 辅助的英语阅读练习 App。用户可以直接生成符合特定学习阶段或考试风格的阅读材料，也可以导入已有文章或阅读题。App 会将不同来源的内容统一转换为内部结构，以支持逐段翻译、答题、原文定位、点击查词和本地学习记录。

产品不尝试给用户计算一个看似精确的“词汇量”，而是根据用户选择的学习阶段、明确反馈和实际阅读行为，轻量调整后续内容的阅读舒适度。

## 2. 设计原则

1. **本地优先**：文章、题目、翻译、答题记录和单词记录均保存在设备本地。
2. **用户自备 API Key**：App 不提供中转服务，不保存或代管用户的模型密钥。
3. **统一内容模型**：AI 生成和用户导入最终都转换为同一种内部数据结构。
4. **AI 任务可校验**：生成文章、生成题目、翻译和格式化拆分为独立步骤，不依赖一次大而不稳定的模型调用。
5. **允许局部失败与重试**：翻译失败时不重新生成文章，单个段落或题目可以单独修复。
6. **不伪造精确能力值**：不展示未经可靠测量的词汇量数字，只表达当前阅读阶段和舒适度趋势。
7. **保留来源与可追溯性**：区分原始导入内容、AI 生成内容和 AI 补全内容。

## 3. 目标用户与核心场景

### 3.1 目标用户

- 希望练习分级英语阅读的学习者。
- 正在准备某一阶段或考试阅读题的用户。
- 已有英文材料，希望快速转换为可练习、可翻译内容的用户。
- 愿意自行配置 OpenAI-compatible 或其他模型 API 的用户。

### 3.2 核心场景

#### 场景 A：AI 生成阅读练习

用户选择学习阶段、主题、文章长度和期望难度，App 根据对应的生成技能生成文章、题目、答案与解析，随后完成逐段翻译并保存。

#### 场景 B：导入纯文章

用户导入英文文章。App 识别文章结构、完成分段、生成阅读题与解析、逐段翻译并保存。

#### 场景 C：导入已有阅读题

用户导入包含文章和题目的内容。App 识别文章、题目、选项、答案与解析：

- 如果已有答案与解析，则保留并格式化。
- 如果只有题目没有答案，则由 AI 补全答案与解析，并明确标记为 AI 生成。
- 如果题目结构不完整，则提示用户确认或进入局部修复流程。

#### 场景 D：阅读与查词

用户逐段阅读英文内容，可以显示或隐藏段落翻译。点击单词后展示单词卡，包含当前词形、原形、发音、当前语境义和所在原句。用户可以明确标记“认识”“学习中”或“不认识”。

## 4. 产品范围

### 4.1 MVP 范围

- iOS 原生 App。
- 粘贴纯文本导入。
- 通过系统 Share Sheet 接收选中的文本。
- AI 生成文章。
- 自动识别“纯文章”或“文章 + 题目”。
- 文章按自然段存储。
- 逐段中文翻译。
- 生成和解析单项选择题、判断题、简答题。
- 本地答题与客观题判分。
- 题目解析定位到原文段落。
- 点击单词查看并缓存语境单词卡。
- 本地阅读历史、生词记录和简单难度偏好。
- 用户配置 API Key、Base URL 和模型名称。

### 4.2 暂不纳入 MVP

- 用户账号和跨设备同步。
- 自有云端服务或 API 中转。
- 精确词汇量测评。
- 社区、排行榜和内容分享平台。
- 支付、订阅和额度管理。
- 任意网页正文抽取。
- PDF 多栏排版恢复。
- 扫描件 OCR 和试卷版面分析。
- 完形填空、段落匹配等复杂题型。
- 自动生成或使用完整的个人词汇知识图谱。

后续可按需求增加 PDFKit 文本提取、Vision OCR、网页导入和更多考试题型。

## 5. 总体架构

```text
SwiftUI / UIKit Reader
        |
ViewModels / Use Cases
        |
+----------------------+----------------------+-------------------+
| ContentPipeline      | ReadingService       | VocabularyService |
| - 生成               | - 阅读进度           | - 分词            |
| - 导入               | - 答题与判分         | - 单词卡          |
| - 解析               | - 难度反馈           | - 本地缓存        |
| - 翻译               |                      |                   |
+----------------------+----------------------+-------------------+
        |                                      |
AIProvider abstraction                  SwiftData
        |
用户配置的云端模型 API
```

推荐技术栈：

- UI：SwiftUI。
- 阅读正文：`UITextView` 经 `UIViewRepresentable` 封装，以获得稳定的单词点击和文本范围定位能力。
- 本地持久化：SwiftData，不配置 CloudKit Container。
- 网络：URLSession、async/await，按供应商能力支持流式响应。
- 密钥：Keychain。
- 分词：NaturalLanguage 的 `NLTokenizer`。
- 朗读：AVFoundation 的 `AVSpeechSynthesizer`。
- 测试：Swift Testing；必要的交互流程使用 XCTest UI。

## 6. 统一内容处理管线

### 6.1 主流程

```text
AI 生成 ----> 结构化草稿 -----------------------------+
                                                    |
用户导入 --> 文本提取 --> 内容分类 --> 结构化草稿 -----+
                                                    |
                                                    v
              结构校验 --> 补齐题目/答案 --> 分段确认
                                                    |
                                                    v
                        逐段翻译 --> 最终校验 --> 保存
```

### 6.2 处理阶段

```swift
enum ProcessingStage: String, Codable {
    case extracting
    case classifying
    case structuring
    case generatingQuestions
    case translating
    case validating
    case completed
    case failed
}
```

每次处理创建一个本地 `ProcessingJob`，记录当前阶段、已完成的产物、错误信息和重试次数。App 被系统终止后，可以从最后一个成功阶段继续。

### 6.3 导入分类结果

```swift
enum ImportedContentKind: String, Codable {
    case articleOnly
    case articleWithQuestions
    case articleWithQuestionsAndAnswers
    case unsupported
}
```

分类结果必须附带置信度。置信度不足或结构存在冲突时，向用户展示识别预览，而不是直接覆盖内容。

### 6.4 AI 调用拆分

AI 生成流程：

1. 根据生成技能生成英文文章。
2. 校验文章长度、段落数和基本难度约束。
3. 基于固定文章生成题目、答案、解析和原文证据。
4. 翻译各段落。
5. 完整性校验，缺失内容局部重试。

用户导入流程：

1. 提取并保留原始文本。
2. 分类内容类型。
3. 将文章、题目、选项、答案解析为统一结构。
4. 根据缺失情况补充题目、答案或解析。
5. 翻译各段落。
6. 完整性校验，必要时让用户确认。

不让单次模型调用同时承担文章创作、题目生成、翻译和最终格式化。

## 7. 阅读生成技能

“技能”在本产品中首先是一组本地、可版本化的生成与出题规则，而不是自主 Agent。技能不依赖特定模型供应商，可以作为 App Bundle 中的 JSON 资源发布。

```swift
struct ReadingSkill: Codable, Identifiable {
    let id: String
    let version: Int
    let displayName: String
    let stage: String
    let supportedGenres: [String]
    let targetWordCount: ClosedRange<Int>
    let paragraphCount: ClosedRange<Int>
    let grammarRequirements: [String]
    let vocabularyConstraints: VocabularyConstraints
    let questionPlan: [QuestionPlanItem]
    let distractorRules: [String]
    let promptInstructions: String
}
```

一个技能至少需要描述：

- 对应学习阶段或考试类别。
- 常见文章体裁和主题范围。
- 文章长度与段落数量。
- 词汇频率和语法复杂度约束。
- 题型、数量与难度比例。
- 细节题、主旨题、推理题等能力分布。
- 选择题干扰项的构造规则。
- 禁止内容和输出格式要求。

技能应记录版本号。已生成的文章保存其 `skillID` 和 `skillVersion`，确保后续修改技能后仍能解释旧内容是如何产生的。

## 8. 阅读难度与轻量个性化

### 8.1 不建立精确词汇量画像

产品不尝试判断用户“掌握了多少个单词”。词汇掌握具有语境、词义、接受性词汇和产出性词汇等差异，单一数字容易误导。

个性化目标缩小为：判断下一篇文章应当更简单、保持不变还是更有挑战。

```swift
struct ReadingPreference: Codable {
    var baseSkillID: String
    var difficultyOffset: Double       // -1.0 ... 1.0
    var targetUnknownWordsPer100: Int
}
```

### 8.2 信号强度

强信号：

- 用户明确标记单词为“认识”“学习中”或“不认识”。
- 用户完成阅读后选择“太简单”“合适”或“太难”。
- 用户主动要求下一篇更简单或更难。

弱信号：

- 单次点击单词。
- 阅读停留时间。
- 未完成文章或中途退出。

单次点击不能直接等同于“不认识”。弱信号只用于很小幅度的调整，不修改单词的明确掌握状态。

### 8.3 难度控制方式

生成时使用以下信息：

- 基础阅读技能及其阶段约束。
- 当前难度偏移量。
- 目标每百词潜在生词数。
- 少量用户明确标记的学习中单词。
- 少量需要避免反复出现的困难单词。

不把全部历史词表发送给模型。文章生成后，App 可使用随包发布且许可兼容的词频数据，对文章本身进行粗略检测。该检测用于描述文章难度，不用于声称用户的真实词汇量。

## 9. 翻译设计

### 9.1 存储粒度

翻译以段落为单位，与英文段落通过稳定 ID 关联。MVP 默认在导入或生成流程中完成全文翻译。

```json
{
  "translations": [
    {"paragraphId": "P1", "text": "……"},
    {"paragraphId": "P2", "text": "……"}
  ]
}
```

App 校验返回结果是否覆盖全部段落，只对缺失或无效段落重试。后续可增加“按需翻译”模式以降低首次等待时间和 API 消耗。

### 9.2 展示方式

- 默认以段落为交互单位显示或隐藏译文。
- 支持全文显示或隐藏翻译。
- 翻译不与英文原文拼接存储，避免修改展示方式时重新解析。
- 记录翻译语言、模型和生成时间，便于将来重新翻译。

## 10. 题目设计

### 10.1 MVP 题型

- 单项选择题。
- 判断题。
- 简答题。

### 10.2 题目来源

```swift
enum ContentOrigin: String, Codable {
    case imported
    case generated
    case aiCompleted
    case userEdited
}
```

导入题目但由 AI 补全的答案，应标记为 `aiCompleted`。用户修改后的内容标记为 `userEdited`。

### 10.3 校验规则

- 选择题答案必须存在于选项中。
- 选项数量满足题型要求且不能重复。
- 每道生成题至少关联一个原文证据段落。
- 解析不能引用不存在的段落。
- 简答题应保存参考答案，但不把模型评分表示为绝对正确。
- 对导入材料保留原答案，AI 补全内容不能无提示地覆盖原内容。

## 11. 本地数据模型

### 11.1 ReadingDocument

- `id`
- `title`
- `sourceType`：generated / imported
- `sourceFormat`
- `rawContent`：原始导入文本，用于恢复和重新解析
- `skillID`
- `skillVersion`
- `difficultyOffset`
- `processingStage`
- `createdAt`
- `updatedAt`

### 11.2 Paragraph

- `id`
- `documentID`
- `order`
- `originalText`
- `translatedText`
- `translationLanguage`
- `translationModel`

### 11.3 Question

- `id`
- `documentID`
- `order`
- `type`
- `stem`
- `options`
- `correctAnswer`
- `explanation`
- `evidenceParagraphIDs`
- `origin`
- `confidence`

### 11.4 Attempt

- `id`
- `documentID`
- `questionID`
- `userAnswer`
- `result`
- `submittedAt`

### 11.5 EncounteredWord

- `id`
- `lemma`
- `surfaceForms`
- `lookupCount`
- `explicitStatus`：known / learning / unknown / unset
- `firstSeenAt`
- `lastSeenAt`

### 11.6 WordCard

- `id`
- `lemma`
- `surfaceForm`
- `paragraphID`
- `sourceSentence`
- `pronunciation`
- `contextualMeaning`
- `generalMeanings`
- `model`
- `createdAt`

同一个单词在不同语境中可能拥有不同的 `WordCard`，但共享同一个 `EncounteredWord` 状态。

### 11.7 ProcessingJob

- `id`
- `documentID`
- `stage`
- `retryCount`
- `lastError`
- `intermediatePayload`
- `updatedAt`

## 12. 点击单词与单词卡

阅读正文使用 `UITextView` 获取点击位置和文本范围，使用 `NLTokenizer` 识别英文单词。处理流程：

1. 将点击位置映射到当前单词范围。
2. 获取当前词形和所在句子。
3. 尝试进行词形归一化，得到 lemma。
4. 查询当前语境是否已有缓存单词卡。
5. 如果没有，调用用户配置的模型生成语境义并保存。
6. 展示单词卡，允许用户明确设置掌握状态。

单词卡至少展示：

- 当前词形和原形。
- 音标或发音入口。
- 当前语境中的中文含义。
- 一到两个常见义。
- 文章原句。
- “认识 / 学习中 / 不认识”操作。

查词应优先返回本地缓存，避免每次点击都产生 API 请求。

## 13. AI Provider 设计

```swift
protocol AIProvider {
    func generateArticle(
        request: ArticleGenerationRequest
    ) async throws -> GeneratedArticle

    func structureImportedContent(
        request: ImportedContentRequest
    ) async throws -> StructuredReadingContent

    func generateQuestions(
        request: QuestionGenerationRequest
    ) async throws -> [ReadingQuestion]

    func translateParagraphs(
        request: TranslationRequest
    ) async throws -> [ParagraphTranslation]

    func generateWordCard(
        request: WordCardRequest
    ) async throws -> GeneratedWordCard
}
```

第一版优先实现 OpenAI-compatible Provider，并允许配置：

- API Key。
- Base URL。
- 模型名称。
- 请求超时时间。
- 是否支持结构化输出。

对接口差异较大的供应商，后续增加独立 Provider。业务层不能直接依赖某一家供应商的请求或响应类型。

## 14. 密钥、安全与隐私

- API Key 仅存入 Keychain，不写入 UserDefaults、SwiftData、日志或导出文件。
- 推荐使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。
- 设置页提供测试连接、替换密钥和删除密钥操作。
- Base URL 默认只允许 HTTPS。
- 日志不得记录 Authorization Header、完整请求体或完整模型响应。
- App 明确告知用户：导入的文章和相关上下文会发送到其选择的模型供应商。
- 删除文章时同步删除关联段落、题目、答题记录和上下文单词卡。
- App 不配置自有遥测和云端分析服务。
- 如未来提供本地数据导出，导出内容不得包含 API Key。

## 15. 主要页面

### 15.1 资料库

- 最近阅读材料。
- 处理中、失败和已完成状态。
- 继续阅读、重新处理和删除。

### 15.2 新建练习

- AI 生成。
- 粘贴或分享文本导入。
- 选择阅读技能、主题、长度和难度偏移。
- 处理进度与局部重试。

### 15.3 识别预览

- 展示识别出的标题、段落和题目数量。
- 标出缺少答案、低置信度或疑似解析错误的内容。
- 允许用户确认后继续翻译和保存。

### 15.4 阅读页

- 文章标题与阅读进度。
- 英文段落。
- 单段或全文翻译开关。
- 点击单词打开单词卡。
- 进入题目区域。

### 15.5 答题与解析

- 提交答案。
- 客观题本地判分。
- 显示解析和原文证据。
- 跳转并高亮对应段落。

### 15.6 单词本

- 认识、学习中、不认识三个状态。
- 最近查询和出现次数。
- 跳转回原文语境。

### 15.7 设置

- 模型供应商、Base URL、模型名称和 API Key。
- 测试连接。
- 默认翻译语言。
- 本地数据删除与导出。

## 16. 错误处理

- 网络错误：保留当前阶段并允许重试。
- API Key 无效：停止新请求，但不影响查看本地文章。
- 模型输出无法解码：执行有限次数的结构修复；仍失败则保留原始内容并提示用户。
- 翻译部分缺失：只重试缺失段落。
- 题目缺失或无有效答案：只重试对应题目。
- App 中断：从 `ProcessingJob` 的最后成功阶段恢复。
- 用户取消：保存已产生的草稿，由用户选择继续或删除。

所有自动重试必须设置上限，避免在用户使用自备 API Key 时意外产生大量费用。

## 17. MVP 验收标准

1. 用户可以配置并验证一个 OpenAI-compatible API。
2. 用户可以通过 AI 生成一篇指定阶段的英文文章。
3. 用户可以粘贴纯文章或带选择题的文本并完成识别。
4. 两种来源均转换为相同的 `ReadingDocument` 结构。
5. 文章按段落保存，并且每个段落具有独立中文翻译。
6. 纯文章可以生成至少一组有效阅读题。
7. 带题目的导入内容能够保留原题；缺失答案时可以补全并标注来源。
8. 选择题答案合法，生成题可以定位到原文证据段落。
9. 用户可以在阅读页点击单词并查看语境单词卡。
10. 单词卡和文章再次打开时优先读取本地缓存。
11. 用户可以明确反馈文章太简单、合适或太难，并影响下一次生成的难度偏移。
12. 网络或模型调用失败不会破坏已经完成的处理结果。
13. API Key 不出现在数据库、日志和数据导出中。

## 18. 后续方向

- PDF 文本提取和扫描件 OCR。
- Safari Share Extension 与网页正文抽取。
- 更多考试技能和可导入的自定义技能包。
- 完形填空、段落匹配和阅读填空。
- 文章与题目的人工编辑器。
- 按需翻译和后台预取。
- 本地词典包，减少基础单词查询的 API 调用。
- 基于间隔重复的单词复习。
- 本地数据备份与跨设备手动迁移。

## 19. 待确认事项

- MVP 首批支持哪些学习阶段或考试类型。
- AI 生成文章是否允许完全自由主题，还是只提供经过筛选的主题范围。
- 导入内容的首批格式是否只支持文本，或同时支持 PDF。
- 翻译默认在处理阶段全部完成，还是允许用户选择按需翻译。
- 简答题第一版是否需要 AI 评分，还是只展示参考答案。
- 阅读技能由 App 内置维护，还是允许用户导入自定义 JSON 技能。
- 是否需要本地数据导出格式，以及是否考虑未来兼容其他平台。
