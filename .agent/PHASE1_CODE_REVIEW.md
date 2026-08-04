# Lection Phase 1 全量代码审查报告

> 审查日期：2026-08-04  
> 审查基线：`main` / `2f5fc1e`  
> 审查范围：`Lection/`、`LectionTests/`、`Lection.xcodeproj`、资源与应用配置，共约 5,620 行  
> 审查方式：逐文件静态审查、调用链核对、资源校验、App 与测试 target 编译验证

## 1. 结论

Phase 1 的基础架构清晰，SwiftData 聚合关系、生成任务分阶段持久化、Keychain 密钥隔离、结构化输出校验和失败恢复均有较完整实现。当前代码可以成功编译，但**不建议直接将 Phase 1 标记为完成**。

主要阻塞点不是编译稳定性，而是“阅读技能契约”与实际成功条件之间存在缺口：模型只要返回格式正确的数据，文章即使不满足词数要求、题目不满足指定类型分布，或者每题不是 4 个选项，也可能被标记为 `.ready`。这会直接影响核心产品结果的可信度。

问题统计：

| 级别 | 数量 | 含义 |
| --- | ---: | --- |
| High | 2 | 应在 Phase 1 验收前修复 |
| Medium | 4 | 会造成错误元数据、误导性状态或数据保存体验问题 |
| Low | 2 | 发布完整性和工程保障缺口 |

## 2. 已确认问题

### H-01：核心阅读技能约束只进入 Prompt，没有进入成功校验

**证据**

- 技能定义包含 `targetWordCount` 和带类别、数量、难度的 `questionPlan`：[ReadingSkill.swift](../Lection/Models/ReadingSkill.swift#L13)、[ReadingSkill.swift](../Lection/Models/ReadingSkill.swift#L17)。
- Prompt 明确要求 350-500 词，并发送题型分布：[ReadingPromptBuilder.swift](../Lection/AI/ReadingPromptBuilder.swift#L78)、[ReadingPromptBuilder.swift](../Lection/AI/ReadingPromptBuilder.swift#L109)。
- `ArticleGenerationRequest` 只携带段落数上下限；`GeneratedQuestion` 没有类别或难度字段：[AIProvider.swift](../Lection/AI/AIProvider.swift#L34)、[AIProvider.swift](../Lection/AI/AIProvider.swift#L97)。
- 文章校验只检查标题、段落数、ID 和空文本；题目校验只检查题目总数，没有检查计划分布：[AIResponseValidator.swift](../Lection/AI/AIResponseValidator.swift#L4)、[AIResponseValidator.swift](../Lection/AI/AIResponseValidator.swift#L50)。
- 这些校验通过后，Pipeline 直接把文档标记为 `.ready`：[GenerationPipeline.swift](../Lection/AI/GenerationPipeline.swift#L186)。

**影响**

- 用户选择“约 375 / 425 / 475 词”后，模型返回远离该目标、甚至超出技能 350-500 词范围的文章仍会成功。
- `2 detail + 1 main idea + 1 inference + 1 vocabulary` 只是模型提示，不是可验证契约；五道同类型题也会成功。
- 当前的 `completed` 更接近“结构可解析”，不能代表“符合阅读技能”。

**建议**

1. 给 `ArticleGenerationRequest` 增加 `minimumWordCount`、`maximumWordCount` 和可选的目标容差，在 Validator 中使用统一的英文词数算法校验。
2. 给 `GeneratedQuestion`、JSON Schema 和持久化模型增加稳定的 `category`（必要时增加 `difficulty`）。
3. 按 `questionPlan` 校验类别计数的完整 multiset，而不只校验题目总数。
4. 增加“边界内/边界外词数”和“题型分布错误触发一次 repair”的测试。

### H-02：“每题恰好 4 个选项”在 Schema、Validator 和测试中被降级为“至少 3 个”

**证据**

- Prompt 明确写着 `Provide exactly four distinct answer options`：[ReadingPromptBuilder.swift](../Lection/AI/ReadingPromptBuilder.swift#L122)。
- JSON Schema 只设置 `minItems: 3`，没有 `maxItems: 4`：[OpenAICompatibleProvider.swift](../Lection/AI/OpenAICompatibleProvider.swift#L444)。
- Validator 仅在少于 3 个选项时报错：[AIResponseValidator.swift](../Lection/AI/AIResponseValidator.swift#L73)。
- 持久化测试还明确断言 3 个选项是合法结果：[PersistenceTests.swift](../LectionTests/PersistenceTests.swift#L38)。

**影响**

模型返回 3 个、5 个或更多选项都可能进入题库并显示给用户，削弱题目一致性，也与产品提示和技能规则冲突。因为现有测试接受 3 个选项，这个偏差会被测试固化。

**建议**

- Schema 同时设置 `minimumCount: 4` 和 `maximumCount: 4`。
- Validator 改为 `options.count != 4`，并使用明确的 `optionCountMismatch` 错误码。
- 把 Preview fixture 和持久化测试统一为 4 个选项；增加 3 个和 5 个选项都失败的测试。

### M-01：失败后更换模型再重试，译文会记录旧模型名称

**证据**

- 创建任务时把当时的模型名写入可恢复请求：[NewPracticeView.swift](../Lection/Features/Create/NewPracticeView.swift#L131)。
- 重试/恢复时 Provider 使用当前最新设置创建：[GenerationCoordinator.swift](../Lection/Features/Create/GenerationCoordinator.swift#L157)。
- 翻译完成后，Paragraph 写入的却是恢复请求中的旧 `translationModel`：[GenerationPipeline.swift](../Lection/AI/GenerationPipeline.swift#L311)。

**复现场景**

1. 使用模型 A 创建任务，翻译阶段失败。
2. 用户去设置页改成模型 B。
3. 从失败阶段重试；实际请求发送给模型 B。
4. 保存的 `Paragraph.translationModel` 仍是模型 A。

**影响**

内容溯源信息不可信。这个场景在 API Key、模型不可用等失败后很常见，不是纯理论边界。

**建议**

- 由 Coordinator 在每次启动/恢复时把实际 Provider 身份作为 execution metadata 传入 Pipeline。
- 在每个产物成功落库时记录实际使用的 base provider/model，而不是初始请求快照。
- 增加“更换模型后从 translating 恢复”的回归测试。

### M-02：测试连接期间仍可修改或删除正在测试的配置

**证据**

- `testConnection()` 在 `await` 前捕获配置和 API Key：[ProviderSettings.swift](../Lection/Features/Settings/ProviderSettings.swift#L92)。
- `settings.isBusy` 只禁用了底部操作 Section：[SettingsView.swift](../Lection/Features/Settings/SettingsView.swift#L68)。
- Base URL、模型名、结构化输出开关、API Key 输入和删除按钮仍保持可操作：[SettingsView.swift](../Lection/Features/Settings/SettingsView.swift#L12)、[SettingsView.swift](../Lection/Features/Settings/SettingsView.swift#L29)、[SettingsView.swift](../Lection/Features/Settings/SettingsView.swift#L34)。

**影响**

用户可以在请求途中把模型 A 改成 B，最终界面却在 B 的输入旁显示“连接成功”，实际成功的是 A。用户也可以在测试期间删除已保存 API Key，请求仍可能成功，形成“连接成功但已无可用密钥”的状态。

**建议**

- 测试期间禁用整张 Form 的可编辑配置和删除动作，只保留状态与取消入口；或显示被测试配置的不可变快照。
- 为测试任务保存 generation/token，完成时只允许当前仍匹配的请求更新状态，防止旧请求覆盖新状态。

### M-03：资料库删除失败被静默吞掉

**证据**

- 删除后使用 `try? modelContext.save()`，没有回滚或用户提示：[LibraryView.swift](../Lection/Features/Library/LibraryView.swift#L50)。

**影响**

保存失败时对象已经在当前 `ModelContext` 中被标记删除，列表可能立即消失，但重启后重新出现。用户无法判断删除是否真正持久化，也无法主动重试。

**建议**

- 显式捕获保存错误并展示 Alert。
- 保存失败时调用 `modelContext.rollback()`，让界面恢复到持久化状态。
- 增加可注入失败的 persistence adapter，覆盖删除失败路径。

### M-04：答题提交保存失败后，界面仍进入不可编辑的“已提交”状态

**证据**

- `submitQuiz()` 先给所有题设置 `answeredAt`，再尝试保存：[ReadingPracticeView.swift](../Lection/Features/Reading/ReadingPracticeView.swift#L295)。
- 保存失败只设置 Alert 文本，没有回滚模型状态：[ReadingPracticeView.swift](../Lection/Features/Reading/ReadingPracticeView.swift#L286)。
- `answeredAt` 全部非空后，选项被禁用且提交按钮消失：[ReadingPracticeView.swift](../Lection/Features/Reading/ReadingPracticeView.swift#L204)、[ReadingPracticeView.swift](../Lection/Features/Reading/ReadingPracticeView.swift#L237)。

**影响**

用户收到“无法保存”提示，但当前页面已经无法重新提交或修改答案。若 App 随后退出，结果可能丢失；若上下文后来自动保存，又可能以用户无法确认的时机落盘。

**建议**

- 保存失败时回滚 `answeredAt` 和 `updatedAt`，保持可提交状态。
- 或在错误状态提供明确的“重新保存”操作，并阻止用户误以为结果已经持久化。
- 对单题选择保存失败也应决定一致策略：回滚选择，或展示“尚未保存”状态。

### L-01：AppIcon 资源槽为空

**证据**

- AppIcon catalog 只有 1024x1024 槽位，没有 `filename`，目录中也没有位图文件：[Contents.json](../Lection/Assets.xcassets/AppIcon.appiconset/Contents.json#L1)。
- 工程指定 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`，但实际没有可编译图标。

**影响**

模拟器编译仍可成功，但安装后会显示占位图标；进入分发/商店验证时这是发布阻塞项。

**建议**

补齐正式 1024x1024 AppIcon，执行 Archive 并检查 asset validation，而不只验证 Debug Simulator build。

### L-02：模型输出没有显式 token/响应体上限

**证据**

- Chat Completions payload 只有 `model`、`messages`、`response_format`：[OpenAICompatibleProvider.swift](../Lection/AI/OpenAICompatibleProvider.swift#L153)、[OpenAICompatibleProvider.swift](../Lection/AI/OpenAICompatibleProvider.swift#L266)。
- 生成响应通过 `dataLoader.data(for:)` 一次性读入内存：[OpenAICompatibleProvider.swift](../Lection/AI/OpenAICompatibleProvider.swift#L179)；默认 loader 最终调用 `URLSession.data(for:)`：[ProviderConnectionTester.swift](../Lection/AI/ProviderConnectionTester.swift#L7)。
- 代码虽然把自动 repair 限制为一次，但单次生成量仍完全由供应商默认值决定。

**影响**

在 BYOK 场景下，不兼容或失控的服务可能返回超大内容，增加费用、延迟和内存压力；repair 会把最坏成本再放大一次。

**建议**

- 按文章、题目、翻译任务分别设置合理的 `max_completion_tokens`（兼容服务需要能力开关时可配置）。
- 使用 delegate/stream 或响应长度门限，在解析前拒绝超过上限的数据。
- 在错误分类中增加“响应过大”，不要把正文写入日志或持久化错误。

## 3. 测试与验证结果

### 已完成

- `xcodebuild build-for-testing` 成功，App 与 `LectionTests` 均完成 Swift 6 编译和链接。
- 使用 Xcode 26.2 SDK、generic iOS Simulator destination、`CODE_SIGNING_ALLOWED=NO`。
- `Info.plist` 校验通过。
- 技能 JSON 与 Asset Catalog JSON 均可由 `jq` 正常解析。
- Base URL 的 `/v1/models` 与 `/v1/chat/completions` 路径拼接结果已单独验证，当前实现正确。
- 工作区在审查前无未提交改动；本报告是唯一新增文件。

### 未完成

- 当前机器没有已启动的 Simulator。按照 iOS 验证流程未擅自启动设备，因此 41 个 `@Test` 只完成编译，**没有实际执行**。
- 未进行运行时 UI、VoiceOver、Dynamic Type、iPad 布局、前后台切换或终止恢复测试。
- 未执行 Release Archive / App Store asset validation。

### 当前测试覆盖评价

现有测试对以下部分覆盖较好：

- Provider HTTP 错误分类、结构化输出 fallback 与一次 repair。
- API Key Keychain 生命周期和非敏感配置持久化。
- SwiftData 关系级联删除与磁盘重开。
- GenerationPipeline 的文章/题目/翻译失败、取消、重试和进程重启恢复。
- Prompt 构建和基础 DTO 校验。

主要缺口：

- 没有词数边界与题型分布的业务验收测试。
- 没有 3/5 个选项必须失败的测试；相反，现有持久化 fixture 接受 3 个选项。
- 没有 Provider 设置变更后恢复任务的溯源测试。
- 没有 `GenerationCoordinator`、`ProviderSettings` 状态竞争测试。
- 没有持久化失败注入与 UI 回滚测试。
- 没有 UI Test target，也没有无障碍和多尺寸快照测试。

## 4. 做得好的部分

- API Key 只存 Keychain，UserDefaults 的 Codable 配置明确不含密钥；Keychain 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。
- 公网 HTTP 被拒绝，本地地址才允许明文连接；Base URL 同时拒绝账号、密码、query 和 fragment。
- 模型错误正文不会直接进入日志；API Key 会从供应商错误信息中替换，持久化只保留分类和用户可读消息。
- 结构化输出同时支持 JSON Schema、JSON Object 和无 response format 的兼容降级，并限制为最多一次自动修复。
- Pipeline 在每一阶段产物落库后保存下一阶段，失败/取消记录了可恢复阶段；这部分设计和测试都相对完整。
- Provider DTO 与 SwiftData ID 分离，避免不同生成任务因供应商复用 UUID 而合并本地对象。
- Swift 6 下对 `Sendable`、actor 和 `@MainActor` 的边界处理清楚，本次编译没有并发错误或警告。

## 5. Phase 1 验收建议

建议按以下顺序收口：

1. 修复 H-02，让 Prompt、Schema、Validator、fixture 和测试统一为恰好 4 个选项。
2. 修复 H-01，至少先落地确定可计算的词数校验与题型类别计数；语法、词汇和内容安全可在后续增加评估层，但不能把所有约束都停留在 Prompt。
3. 修复 M-01，保证恢复/重试使用的实际模型与持久化 provenance 一致。
4. 修复设置页 busy 状态和两条持久化失败路径。
5. 补齐 AppIcon，运行全部 41 个测试、iPhone/iPad 基础 UI 检查和 Release Archive。

完成以上 High 与 Medium 问题，并实际运行现有测试后，再将 Phase 1 标记为通过更稳妥。

## 6. 收口更新（2026-08-04）

以下状态对应本报告第 2 节的原始问题；原始审查结论、证据和建议均保留，以便追溯。

| 编号 | 当前状态 | 收口说明 |
| --- | --- | --- |
| H-01 | 已修复 | 词数范围与目标容差进入请求和校验器；题目新增 `category`、`difficulty`，按 `questionPlan` 的完整分布校验，并在 SwiftData 落库后的最终校验中复核。 |
| H-02 | 已修复 | JSON Schema、响应校验、Preview fixture 和持久化测试统一为恰好 4 个选项。 |
| M-01 | 已修复 | Coordinator 将本次实际 Provider 模型名传入 Pipeline，译文保存该执行模型而非创建草稿时的旧模型。 |
| M-02 | 已修复 | 保存或测试连接期间禁用完整设置表单，避免被测配置在请求途中改变。 |
| M-03 | 已修复 | 删除保存失败时回滚 `ModelContext` 并展示错误提示。 |
| M-04 | 已修复 | 选择答案或提交答案保存失败时调用 `ModelContext.rollback()`，页面恢复可编辑状态。 |
| L-01 | 待处理 | AppIcon 仍需由产品资产补齐，并以 Release Archive 验证。 |
| L-02 | 部分缓解 | Provider 在 JSON 解码前拒绝超过 2 MB 的响应，并有 `responseTooLarge` 错误分类；仍建议增加 completion token 上限和流式长度限制。 |

### 更新后的验证

- `xcodebuild build-for-testing` 通过。
- iPhone 17 Pro Simulator 中，排除缺少 Keychain entitlement 的单测后，45 个测试、7 个 suite 通过。
- 真机端到端闭环验证已完成。
- Keychain 生命周期测试在未签名 Simulator 测试进程中返回 `errSecMissingEntitlement`（`-34018`）；该单测仍需在带 entitlement 的签名环境复验。

因此，本报告原先的“完成全部 High 与 Medium 后再标记通过”的门槛及真机端到端验证均已满足；L-01、L-02 的剩余发布事项仍应在发布前完成。
