import Foundation

struct PromptBuilder {
    static func prompt(
        for lane: AnswerLane,
        currentSegment: String,
        history500: String,
        answerHistory: [String],
        candidates: [AnswerLane: String] = [:]
    ) -> String {
        switch lane {
        case .current:
            return """
            当前语音片段：
            \(currentSegment)
            """

        case .history500:
            return """
            最近历史：
            \(history500.isEmpty ? "无" : history500)

            当前语音片段：
            \(currentSegment)
            """

        case .answerMemory:
            let answers = answerHistory.isEmpty ? "无" : answerHistory.enumerated().map { index, answer in
                "\(index + 1). \(answer)"
            }.joined(separator: "\n")

            return """
            最近模型回答：
            \(answers)

            当前语音片段：
            \(currentSegment)
            """

        case .fusion:
            let lines = [AnswerLane.current, .history500, .answerMemory].map { lane in
                "\(lane.title)：\(candidates[lane]?.isEmpty == false ? candidates[lane]! : "空字符串")"
            }.joined(separator: "\n")

            return """
            当前语音片段：
            \(currentSegment)

            候选回答：
            \(lines)

            请选择一个最适合实时显示的回答。若都无必要，返回空字符串。
            要求：短、直接、不可编造、不要解释选择过程。
            """
        }
    }
}
