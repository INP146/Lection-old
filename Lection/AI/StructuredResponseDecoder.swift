import Foundation

enum StructuredResponseDecoder {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from content: String
    ) throws -> Value {
        let decoder = JSONDecoder()
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let value = try? decoder.decode(Value.self, from: Data(trimmedContent.utf8)) {
            return value
        }

        // 部分兼容服务会在 JSON 外包裹 Markdown 围栏或简短说明；只提取平衡的 JSON 值再交给 JSONDecoder。
        for candidate in balancedJSONCandidates(in: trimmedContent) {
            if let value = try? decoder.decode(Value.self, from: Data(candidate.utf8)) {
                return value
            }
        }

        throw AIProviderError.outputDecodingFailed
    }

    private static func balancedJSONCandidates(in content: String) -> [String] {
        let scalars = Array(content.unicodeScalars)
        var candidates: [String] = []
        var startIndex: Int?
        var stack: [UnicodeScalar] = []
        var isInsideString = false
        var isEscaped = false

        for (index, scalar) in scalars.enumerated() {
            if startIndex == nil {
                guard scalar == "{" || scalar == "[" else { continue }
                startIndex = index
                stack = [scalar]
                continue
            }

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInsideString = false
                }
                continue
            }

            if scalar == "\"" {
                isInsideString = true
            } else if scalar == "{" || scalar == "[" {
                stack.append(scalar)
            } else if scalar == "}" || scalar == "]" {
                guard let opening = stack.last,
                      (opening == "{" && scalar == "}") || (opening == "[" && scalar == "]") else {
                    startIndex = nil
                    stack.removeAll(keepingCapacity: true)
                    continue
                }

                stack.removeLast()
                if stack.isEmpty, let candidateStartIndex = startIndex {
                    let candidate = String(String.UnicodeScalarView(scalars[candidateStartIndex...index]))
                    candidates.append(candidate)
                    startIndex = nil
                    isInsideString = false
                    isEscaped = false
                }
            }
        }

        return candidates
    }
}
