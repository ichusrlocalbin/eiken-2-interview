import Foundation
import FoundationModels

/// よくあるミスの種類（履歴の集計用）。判定結果からプログラムで付ける
enum MistakeTag: String, Codable, CaseIterable {
    case thirdPersonS
    case tense
    case articleOrPlural
    case wordOrder
    case grammar
    case oneReasonOnly
    case noReason
    case noClearPosition
    case offTopic
    case copiedPassage
    case missingKeyPoint
    case tooShort
    case missingPanelDetail
    case noOpeningSentence
    case fillers
    case manyPardons

    var label: String {
        switch self {
        case .thirdPersonS: "三単現の s"
        case .tense: "時制"
        case .articleOrPlural: "冠詞・複数形"
        case .wordOrder: "語順"
        case .grammar: "文法"
        case .oneReasonOnly: "理由が1つだけ"
        case .noReason: "理由がない"
        case .noClearPosition: "立場があいまい"
        case .offTopic: "質問からずれている"
        case .copiedPassage: "“By doing so” をそのまま言う"
        case .missingKeyPoint: "答えの要点が足りない"
        case .tooShort: "回答が短い"
        case .missingPanelDetail: "コマの描写不足"
        case .noOpeningSentence: "最初の文から始めていない"
        case .fillers: "“uh” “um” が多い"
        case .manyPardons: "聞き返しが多い"
        }
    }
}

// MARK: - AI に頼む判定（抜き出し・確認・言い直しだけ。点数は ScoringRules で計算する）

@Generable
struct No1Judgement {
    @Guide(description: "受験者の回答が、質問の答えになっているか")
    var answersQuestion: Bool
    @Guide(description: "採点の観点のうち、受験者の回答に含まれている観点の番号（0から始まる）。含まれていなければ空")
    var coveredKeyPoints: [Int]
    @Guide(description: "文法: 2=ほぼ正しい 1=誤りあるが伝わる 0=伝わりにくい", .range(0...2))
    var grammarLevel: Int
    @Guide(description: "回答の内容は変えず、文法の誤りだけ直した英文（uh, um などは除く）")
    var correctedAnswer: String
}

@Generable
struct No2Judgement {
    @Guide(description: "各コマの要点のうち、受験者の回答で説明できている要点の記号（例: \"1-1\", \"2-2\"）。説明できていなければ空")
    var coveredKeyPoints: [String]
    @Guide(description: "全体を通して、過去形・過去進行形で話せているか")
    var tenseConsistent: Bool
    @Guide(description: "文法: 2=ほぼ正しい 1=誤りあるが伝わる 0=伝わりにくい", .range(0...2))
    var grammarLevel: Int
    @Guide(description: "回答の内容は変えず、文法の誤りだけ直した英文（uh, um などは除く）")
    var correctedAnswer: String
}

@Generable
struct OpinionJudgement {
    @Guide(description: "受験者の立場を支える理由を、受験者の回答の英語からそのまま抜き出したもの。立場をくり返しただけの文、質問と関係ない文、つなぎ言葉は含めない。理由がなければ空")
    var reasons: [String]
    @Guide(description: "文法: 2=ほぼ正しい 1=誤りあるが伝わる 0=伝わりにくい", .range(0...2))
    var grammarLevel: Int
    @Guide(description: "回答の内容は変えず、文法の誤りだけ直した英文（uh, um などは除く）")
    var correctedAnswer: String
}

/// No.1〜4 の採点。AI には判定と言い直しだけを頼み、点数とフィードバックの文はプログラムで決める
enum AIScorer {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    static let instructions = """
    あなたは英検2級の二次試験（面接）の採点補助です。受験者は日本の中学3年生です。
    受験者の回答は音声認識で文字に起こしたものです。多少の認識ミスがあっても、意味が通じていればその内容を言えたものとして扱ってください。
    指示された項目を、回答に実際に書かれている内容だけをもとに判定してください。書かれていないことを補ったり、推測したりしないでください。
    """

    /// 失敗したら新しいセッションで1回だけやり直す
    private static func judge<T: Generable>(_ prompt: String, as type: T.Type) async throws -> T {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                // 音声認識の聞き間違いで安全チェックに誤って引っかからないよう、文章を扱う用途向けの設定を使う
                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt, generating: type, options: GenerationOptions(temperature: 0.1))
                return response.content
            } catch {
                print("[AIScorer] 判定に失敗（\(attempt + 1)回目）: \(error)")
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    // MARK: - No.1

    static func scoreNo1(problem: ProblemSet, transcript: Transcript, audio: [String]) async -> ItemOutcome {
        let q = problem.no1
        if let empty = emptyOutcome(.no1, transcript, audio, q.modelAnswer) { return empty }

        let prompt = """
        ## 質問
        \(q.question)
        ## パッセージ
        \(problem.passage)
        ## 模範解答
        \(orNone(q.modelAnswer))
        ## 採点の観点
        \(numbered(q.keyPoints))
        ## 受験者の回答
        \(transcript.text)
        """
        do {
            let j = try await judge(prompt, as: No1Judgement.self)
            let covered = Set(j.coveredKeyPoints.filter { q.keyPoints.indices.contains($0) })
            let repeatsCue = ScoringRules.repeatsCue(transcript.text)
            // 要点がすべて含まれていれば、答えになっているとみなす（AI の判定の矛盾を防ぐ）
            let answersQuestion = j.answersQuestion || (!q.keyPoints.isEmpty && covered.count == q.keyPoints.count)
            let score = ScoringRules.no1Score(
                keyPointCount: q.keyPoints.count, covered: covered.count,
                answersQuestion: answersQuestion, repeatsCue: repeatsCue, grammarLevel: j.grammarLevel
            )

            var good: [String] = []
            var improve: [String] = []
            var tags: [MistakeTag] = []
            let missing = q.keyPoints.indices.filter { !covered.contains($0) }.map { q.keyPoints[$0] }

            if answersQuestion && missing.isEmpty {
                good.append("質問の答えになる部分を、パッセージから正しく見つけられています。")
            } else if !answersQuestion && covered.isEmpty {
                improve.append("質問の答えになっていません。“How ...?” には “By ~ing.” か “They ~.” の形で答えよう。")
                tags.append(.offTopic)
            }
            if !missing.isEmpty && !covered.isEmpty || !missing.isEmpty && answersQuestion {
                improve.append("答えに足りない部分があります（\(missing.joined(separator: "／"))）。")
                tags.append(.missingKeyPoint)
            }
            if repeatsCue {
                improve.append("“By doing so” などはそのまま言わずに、それが指す中身を答えよう。")
                tags.append(.copiedPassage)
            }
            if j.grammarLevel >= 2 {
                good.append("文法も正しく言えています。")
            } else {
                improve.append(grammarAdvice(j.grammarLevel))
                tags.append(.grammar)
            }
            return ItemOutcome(
                kind: .no1, score: score, transcript: transcript.text, audioFiles: audio,
                goodPoints: Array(good.prefix(2)), improvements: Array(improve.prefix(2)),
                modelAnswer: q.modelAnswer, tags: tags.map(\.rawValue),
                correctedAnswer: corrected(j.correctedAnswer, original: transcript.text)
            )
        } catch {
            return estimated(.no1, transcript, audio, q.modelAnswer, score: lengthScore(transcript, [(8, 3), (3, 2)], minimum: 1), error: error)
        }
    }

    // MARK: - No.2

    static func scoreNo2(problem: ProblemSet, transcript: Transcript, audio: [String]) async -> ItemOutcome {
        let q = problem.no2
        if let empty = emptyOutcome(.no2, transcript, audio, q.modelAnswer) { return empty }

        let panelLines = q.panels.enumerated().flatMap { panelIndex, panel in
            panel.keyPoints.enumerated().map { pointIndex, point in
                let label = panel.timeLabel.map { "（\($0)）" } ?? ""
                return "\(panelIndex + 1)-\(pointIndex + 1): \(panelIndex + 1)コマ目\(label) \(point)"
            }
        }
        let prompt = """
        3コマのイラストを見て、指定された文から始めて英語で説明する問題です。
        ## 指定された最初の文
        \(q.openingSentence)
        ## 各コマの要点（記号: 内容）
        \(panelLines.isEmpty ? "（指定なし。模範解答と比べてください）" : panelLines.joined(separator: "\n"))
        ## 模範解答
        \(orNone(q.modelAnswer))
        ## 受験者の回答
        \(transcript.text)
        """
        let startedWithOpening = ScoringRules.startsWith(transcript.text, q.openingSentence)
        let contentWords = ScoringRules.contentWordCount(transcript.text)
        do {
            let j = try await judge(prompt, as: No2Judgement.self)
            let covered = Set(j.coveredKeyPoints.map { $0.trimmingCharacters(in: .whitespaces) })
            let panels = q.panels.enumerated().map { panelIndex, panel in
                (covered: panel.keyPoints.indices.filter { covered.contains("\(panelIndex + 1)-\($0 + 1)") }.count,
                 total: panel.keyPoints.count)
            }
            let score = ScoringRules.no2Score(
                panels: panels, tenseConsistent: j.tenseConsistent, startedWithOpening: startedWithOpening,
                grammarLevel: j.grammarLevel, contentWords: contentWords
            )

            var good: [String] = []
            var improve: [String] = []
            var tags: [MistakeTag] = []
            if !startedWithOpening {
                improve.append("カードに書かれた最初の文から話し始めよう。")
                tags.append(.noOpeningSentence)
            } else {
                good.append("カードの最初の文から始められています。")
            }
            let missing = q.panels.enumerated().flatMap { panelIndex, panel in
                panel.keyPoints.enumerated()
                    .filter { !covered.contains("\(panelIndex + 1)-\($0.offset + 1)") }
                    .map { "\(panelIndex + 1)コマ目: \($0.element)" }
            }
            if missing.isEmpty {
                good.append("3コマすべての場面を説明できています。")
            } else {
                improve.append("説明が足りないところがあります（\(missing.prefix(2).joined(separator: "／"))）。")
                tags.append(.missingPanelDetail)
            }
            if j.tenseConsistent {
                good.append("過去形・過去進行形で話せています。")
            } else {
                improve.append("過去形・過去進行形でそろえて話そう（例: was cooking, ordered）。")
                tags.append(.tense)
            }
            if j.grammarLevel < 2 { tags.append(.grammar) }
            if contentWords < 15 { tags.append(.tooShort) }
            return ItemOutcome(
                kind: .no2, score: score, transcript: transcript.text, audioFiles: audio,
                goodPoints: Array(good.prefix(2)), improvements: Array(improve.prefix(2)),
                modelAnswer: q.modelAnswer, tags: tags.map(\.rawValue),
                correctedAnswer: corrected(j.correctedAnswer, original: transcript.text)
            )
        } catch {
            return estimated(.no2, transcript, audio, q.modelAnswer, score: lengthScore(transcript, [(40, 6), (20, 4)], minimum: 2), error: error)
        }
    }

    // MARK: - No.3 / No.4

    static func scoreOpinion(_ kind: ItemKind, question: String, hints: [String], modelAnswer: String, transcript: Transcript, audio: [String]) async -> ItemOutcome {
        if let empty = emptyOutcome(kind, transcript, audio, modelAnswer) { return empty }

        let prompt = """
        社会的な話題について、受験者が自分の意見を述べる問題です。
        ## 質問
        \(question)
        ## 模範解答の例
        \(orNone(modelAnswer))
        ## 受験者の回答
        \(transcript.text)
        """
        let positionClear = ScoringRules.hasPositionMarker(transcript.text)
        let contentWords = ScoringRules.contentWordCount(transcript.text)
        do {
            let j = try await judge(prompt, as: OpinionJudgement.self)
            let reasons = ScoringRules.verifiedReasons(j.reasons, in: transcript.text, question: question)
            // AI が2つの理由を1つにまとめることがあるので、文ごとの数え方と多いほうを使う
            let reasonCount = max(reasons.count, ScoringRules.sentenceReasonCount(transcript.text, question: question))
            let score = ScoringRules.opinionScore(
                positionClear: positionClear, reasonCount: reasonCount, grammarLevel: j.grammarLevel, contentWords: contentWords
            )

            var good: [String] = []
            var improve: [String] = []
            var tags: [MistakeTag] = []
            if positionClear {
                good.append("自分の立場を伝えられています。")
            } else {
                improve.append(kind == .no4
                    ? "最初に “Yes.” か “No.” をはっきり言おう。"
                    : "最初に “I agree.” か “I disagree.” をはっきり言おう。")
                tags.append(.noClearPosition)
            }
            switch reasonCount {
            case 0:
                improve.append("理由を言おう。“Because ...” で始めると言いやすいよ。")
                tags.append(.noReason)
            case 1:
                improve.append("理由をもう1つ足そう。2つ目は “Also, ...” で始めると言いやすいよ。")
                tags.append(.oneReasonOnly)
            default:
                good.append("理由を2つ挙げられています。")
            }
            if j.grammarLevel >= 2 {
                good.append("文法も正しく言えています。")
            } else {
                improve.append(grammarAdvice(j.grammarLevel))
                tags.append(.grammar)
            }
            if contentWords < 8 { tags.append(.tooShort) }
            return ItemOutcome(
                kind: kind, score: score, transcript: transcript.text, audioFiles: audio,
                goodPoints: Array(good.prefix(2)), improvements: Array(improve.prefix(2)),
                modelAnswer: modelAnswer, tags: tags.map(\.rawValue),
                correctedAnswer: corrected(j.correctedAnswer, original: transcript.text)
            )
        } catch {
            return estimated(kind, transcript, audio, modelAnswer, score: lengthScore(transcript, [(20, 3), (8, 2)], minimum: 1), error: error)
        }
    }

    // MARK: - Helpers

    private static func grammarAdvice(_ level: Int) -> String {
        level == 0
            ? "文法の誤りが多く、伝わりにくいところがあります。下の「あなたの回答を直すと」を声に出して練習しよう。"
            : "文法の小さな誤りがあります。下の「あなたの回答を直すと」と比べてみよう。"
    }

    /// AI の言い直しが空・回答とほぼ同じ・英文でない場合は表示しない
    private static func corrected(_ text: String, original: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ScoringRules.containsJapanese(trimmed) else { return nil }
        let cleanedOriginal = ScoringRules.words(original).filter { !ScoringRules.fillers.contains($0) }
        return ScoringRules.words(trimmed) == cleanedOriginal ? nil : trimmed
    }

    private static func numbered(_ items: [String]) -> String {
        guard !items.isEmpty else { return "（指定なし。模範解答と比べて判定してください）" }
        return items.enumerated().map { "\($0): \($1)" }.joined(separator: "\n")
    }

    /// 自分で追加した問題では模範解答が空のことがある
    private static func orNone(_ text: String) -> String {
        text.isEmpty ? "（なし）" : text
    }

    private static func emptyOutcome(_ kind: ItemKind, _ transcript: Transcript, _ audio: [String], _ model: String) -> ItemOutcome? {
        guard ScoringRules.contentWordCount(transcript.text) == 0 else { return nil }
        return ItemOutcome(
            kind: kind, score: 0, transcript: transcript.text, audioFiles: audio,
            goodPoints: [],
            improvements: ["回答が聞き取れませんでした。分からないときも、知っている単語で何か答えてみよう。"],
            modelAnswer: model, tags: [MistakeTag.tooShort.rawValue]
        )
    }

    private static func estimated(_ kind: ItemKind, _ transcript: Transcript, _ audio: [String], _ model: String, score: Int, error: Error) -> ItemOutcome {
        ItemOutcome(
            kind: kind, score: score, transcript: transcript.text, audioFiles: audio,
            goodPoints: [],
            improvements: ["AIの採点ができなかったため、回答の長さから目安の点数を出しています。模範解答と比べてみよう。"],
            modelAnswer: model, tags: [], isEstimated: true,
            scoringError: describe(error)
        )
    }

    /// 失敗の種類が分かるように、GenerationError は名前で記録する
    private static func describe(_ error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            return "GenerationError: \(generationError)"
        }
        return String(describing: error)
    }

    private static func lengthScore(_ transcript: Transcript, _ steps: [(words: Int, score: Int)], minimum: Int) -> Int {
        let count = ScoringRules.contentWordCount(transcript.text)
        return steps.first { count >= $0.words }?.score ?? minimum
    }
}
