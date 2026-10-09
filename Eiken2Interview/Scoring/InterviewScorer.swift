import Foundation

/// 面接1回分の録音・文字起こしから全項目を採点する
@MainActor
struct InterviewScorer {
    let problem: ProblemSet
    let recordings: [AnswerKey: Recording]
    let transcripts: [AnswerKey: Transcript]
    let reprompts: Int
    /// 受験者が聞き返した回数
    var pardons: Int = 0
    /// 採点する項目（本番モードは全項目）
    var items: Set<ItemKind> = Set(ItemKind.allCases)

    func score(progress: (String) -> Void) async -> [ItemOutcome] {
        func t(_ key: AnswerKey) -> Transcript { transcripts[key] ?? .empty }
        func audio(_ keys: AnswerKey...) -> [String] { keys.compactMap { recordings[$0]?.relativePath } }
        var results: [ItemOutcome] = []

        if items.contains(.reading) {
            progress("音読をチェックしています…")
            var reading = ReadingScorer.score(passage: "\(problem.title). \(problem.passage)", transcript: t(.reading), recording: recordings[.reading])
            reading.question = InterviewScript.readAloud
            results.append(reading)
        }
        if items.contains(.no1) {
            progress("No.1 を採点しています…")
            var no1 = await AIScorer.scoreNo1(problem: problem, transcript: t(.no1), audio: audio(.no1))
            no1.question = InterviewScript.no1(problem)
            results.append(no1)
        }
        if items.contains(.no2) {
            progress("No.2 を採点しています…")
            var no2 = await AIScorer.scoreNo2(problem: problem, transcript: t(.no2), audio: audio(.no2))
            no2.question = InterviewScript.no2
            results.append(no2)
        }
        if items.contains(.no3) {
            progress("No.3 を採点しています…")
            var no3 = await AIScorer.scoreOpinion(
                .no3, question: problem.no3.question, hints: problem.no3.rubricHints,
                modelAnswer: problem.no3.modelAnswer, transcript: t(.no3), audio: audio(.no3)
            )
            no3.question = InterviewScript.no3(problem)
            results.append(no3)
        }
        if items.contains(.no4) {
            progress("No.4 を採点しています…")
            let first = t(.no4)
            let isNo = OpinionDetector.position(of: first.text) == .no
            let combined = Transcript(
                text: [first.text, t(.no4Why).text].filter { !$0.isEmpty }.joined(separator: " "),
                words: []
            )
            var no4 = await AIScorer.scoreOpinion(
                .no4, question: problem.no4.question, hints: problem.no4.rubricHints,
                modelAnswer: isNo ? problem.no4.modelAnswerNo : problem.no4.modelAnswerYes,
                transcript: combined, audio: audio(.no4, .no4Why)
            )
            no4.question = InterviewScript.no4(problem) + "\n" + InterviewScript.no4FollowUp(first.text)
            results.append(no4)
        }
        if items.contains(.attitude) {
            let answers: [AnswerKey] = [.no1, .no2, .no3, .no4, .no4Why]
            let fillers = answers.map { ScoringRules.fillerCount(t($0).text) }.reduce(0, +)
            results.append(AttitudeScorer.score(recordings: recordings, reprompts: reprompts, pardons: pardons, fillers: fillers))
        }
        return results
    }

    /// 得点率が一番低い項目の改善点を「次回に意識すること」にする
    static func summaryAdvice(_ items: [ItemOutcome]) -> String {
        if items.allSatisfy({ $0.ratio >= 0.8 }) {
            return "とてもよくできています！ 本番も同じように、落ち着いてはっきり答えよう。"
        }
        guard let weakest = items.filter({ !$0.improvements.isEmpty }).min(by: { $0.ratio < $1.ratio }),
              let advice = weakest.improvements.first
        else {
            return "模範解答を声に出して読んで、言い回しをまねしてみよう。"
        }
        return "【\(weakest.kind.shortTitle)】\(advice)"
    }
}

/// 面接官のセリフ（面接中の読み上げと結果画面の表示で共通）
enum InterviewScript {
    static let greeting = "Hello. Please have a seat. This is the Grade 2 test. How are you today?"
    static let readSilently = "First, please read the passage silently for 20 seconds."
    static let readAloud = "All right. Now, please read it aloud."
    static let no2 = "No. 2. Now, please look at the picture and describe the situation. You have 20 seconds to prepare. Your story should begin with the sentence on the card."

    static func no1(_ p: ProblemSet) -> String { "No. 1. \(p.no1.question)" }
    static func no3(_ p: ProblemSet) -> String { "No. 3. \(p.no3.question)" }
    static func no4(_ p: ProblemSet) -> String { "No. 4. \(p.no4.question)" }

    /// No.4 の1回目の回答に応じた聞き返し
    static func no4FollowUp(_ firstAnswer: String) -> String {
        switch OpinionDetector.position(of: firstAnswer) {
        case .yes: "Why?"
        case .no: "Why not?"
        case .unknown: "Why do you think so?"
        }
    }
}

enum AnswerKey: String, CaseIterable {
    case greeting, reading, no1, no2, no3, no4, no4Why
}

enum OpinionDetector {
    enum Position { case yes, no, unknown }

    /// No.4 の1回目の回答から Yes/No を判定する（"Why?" / "Why not?" の出し分け用）
    static func position(of text: String) -> Position {
        let head = text.lowercased().split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let noPatterns = ["no", "no,", "no.", "i don't think", "i do not think", "i disagree", "nope"]
        let yesPatterns = ["yes", "yes,", "yes.", "i think so", "i agree", "yeah", "sure"]
        if noPatterns.contains(where: { head.hasPrefix($0) || head.contains(" \($0)") && $0.count > 3 }) { return .no }
        if yesPatterns.contains(where: { head.hasPrefix($0) || head.contains(" \($0)") && $0.count > 3 }) { return .yes }
        return .unknown
    }
}

/// アティチュード（態度）の簡易採点。カメラは使わず音声の情報だけで判定する。
enum AttitudeScorer {
    /// 聞き返しが何回から減点になるか（英検は「くり返し聞き返すと減点」としている。回数は非公表なので3回とする）
    static let pardonPenaltyThreshold = 3

    static func score(recordings: [AnswerKey: Recording], reprompts: Int, pardons: Int = 0, fillers: Int = 0) -> ItemOutcome {
        let answerKeys: [AnswerKey] = [.no1, .no2, .no3, .no4]
        let latencies = answerKeys.compactMap { recordings[$0]?.firstSpeechAt }
        let average = latencies.isEmpty ? .infinity : latencies.reduce(0, +) / Double(latencies.count)
        let greeted = recordings[.greeting]?.firstSpeechAt != nil

        var score = 3
        var good: [String] = []
        var improvements: [String] = []

        if average <= 4 {
            good.append("質問のあと、すぐに答え始められています。")
        } else {
            score -= 1
            improvements.append("答え始めるまでに時間がかかっています。考えるときは “Well, ...” や “Let me see.” と言ってつなごう。")
        }
        if reprompts >= 2 {
            score -= 1
            improvements.append("無言の時間が長く、聞き返されることがありました。分からなくても何か答えよう。")
        } else if reprompts == 0 {
            good.append("どの質問にもしっかり反応できています。")
        }
        if pardons >= pardonPenaltyThreshold {
            score -= 1
            improvements.insert("聞き返しが多めでした（\(pardons)回）。英検では、くり返し聞き返すと減点されます。質問の最初の疑問詞（What / Why / Do you ...）を特によく聞こう。", at: 0)
        } else if pardons > 0 {
            good.insert("聞き取れなかったときに、英語で聞き返せています。", at: 0)
        }
        if greeted {
            good.append("あいさつにきちんと答えられています。")
        } else {
            score -= 1
            improvements.append("最初のあいさつ（How are you? など）にも、元気に答えよう。例: “I'm fine, thank you.”")
        }

        var tags: [String] = []
        if pardons >= pardonPenaltyThreshold { tags.append(MistakeTag.manyPardons.rawValue) }
        // つなぎ言葉は減点しないが、多いときは改善点として伝える
        if fillers >= 6 {
            improvements.append("“uh” “um” が多めです（\(fillers)回）。考えるときは “Well, ...” や “Let me see.” を使うと自然に聞こえるよ。")
            tags.append(MistakeTag.fillers.rawValue)
        }

        return ItemOutcome(
            kind: .attitude, score: max(0, score), transcript: "", audioFiles: [],
            goodPoints: Array(good.prefix(2)), improvements: Array(improvements.prefix(2)),
            modelAnswer: nil, tags: tags
        )
    }
}
