import Foundation

/// 採点のうち AI を使わない部分（点数の計算・回答の確認）。
/// FoundationModels に依存しないので、Mac 上のスクリプトでもテストできる。
enum ScoringRules {
    // MARK: - テキスト処理

    static func normalize(_ token: String) -> String {
        token.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "?" || $0 == "!" })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    static let fillers: Set<String> = ["uh", "um", "umm", "hmm", "ah", "er", "erm", "eh"]

    /// "uh" "um" などのつなぎ言葉の数
    static func fillerCount(_ text: String) -> Int {
        words(text).filter(fillers.contains).count
    }

    /// つなぎ言葉を除いた単語数
    static func contentWordCount(_ text: String) -> Int {
        words(text).filter { !fillers.contains($0) }.count
    }

    static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    // MARK: - No.1

    static let cues = ["by doing so", "in this way", "by doing this"]

    /// "By doing so" などをそのまま言ってしまっているか（中身に言い換えられていない）
    static func repeatsCue(_ text: String) -> Bool {
        let lower = words(text).joined(separator: " ")
        return cues.contains { lower.contains($0) }
    }

    /// No.1（5点）: 要点が足りないと1つにつき -1（最大 -2）、"By doing so" をそのまま言うと -1、文法が「伝わるが誤りあり」以下で -1
    static func no1Score(keyPointCount: Int, covered: Int, answersQuestion: Bool, repeatsCue: Bool, grammarLevel: Int) -> Int {
        if !answersQuestion && covered == 0 { return 1 }
        let missing = max(0, keyPointCount - covered)
        var score = 5 - min(2, missing)
        if repeatsCue { score -= 1 }
        if grammarLevel <= 1 { score -= 1 }
        return max(1, score)
    }

    // MARK: - No.2

    /// No.2（10点）: 各コマ 2点 × 3（要点のうち描写できた割合）＋ 時制 2点 ＋ 最初の文 1点 ＋ 文法 1点
    static func no2Score(panels: [(covered: Int, total: Int)], tenseConsistent: Bool, startedWithOpening: Bool, grammarLevel: Int, contentWords: Int) -> Int {
        let panelPoints = panels.prefix(3).map { panel -> Int in
            guard panel.total > 0 else { return contentWords >= 10 ? 2 : 1 }
            return Int((Double(min(panel.covered, panel.total)) / Double(panel.total) * 2).rounded())
        }.reduce(0, +)
        var score = panelPoints + (tenseConsistent ? 2 : 0) + (startedWithOpening ? 1 : 0) + (grammarLevel >= 2 ? 1 : 0)
        if contentWords < 15 { score = min(score, 4) }
        return min(10, score)
    }

    /// 回答の冒頭が指定文とおおむね一致しているか（つなぎ言葉は除く）
    static func startsWith(_ text: String, _ opening: String) -> Bool {
        let openingWords = words(opening)
        guard !openingWords.isEmpty else { return true }
        let head = Set(words(text).filter { !fillers.contains($0) }.prefix(openingWords.count + 3))
        let hit = openingWords.filter { head.contains($0) }.count
        return Double(hit) / Double(openingWords.count) >= 0.6
    }

    // MARK: - No.3 / No.4

    static let positionMarkers = [
        "i agree", "i disagree", "i don't agree", "i do not agree", "i think", "i don't think", "i do not think",
        "yes", "no", "i believe", "in my opinion", "i'm for", "i'm against",
    ]

    /// 冒頭（最初の12語）で立場を表す言い方をしているか
    static func hasPositionMarker(_ text: String) -> Bool {
        let head = " " + words(text).prefix(12).joined(separator: " ") + " "
        return positionMarkers.contains { head.contains(" \($0) ") }
    }

    static let stopWords: Set<String> = ["i", "think", "so", "that", "the", "a", "an", "to", "is", "are", "should", "will", "more", "it", "they", "we", "and", "of", "in"]

    /// AI が抜き出した理由のうち、実際に回答の中にあるもの（単語の6割以上が回答に含まれる）だけを残す。
    /// 質問文をくり返しただけの文（立場のくり返し）は理由として数えない
    static func verifiedReasons(_ reasons: [String], in transcript: String, question: String = "") -> [String] {
        let answerWords = Set(words(transcript))
        let questionWords = Set(words(question))
        var result: [String] = []
        for reason in reasons {
            let reasonWords = words(reason).filter { !fillers.contains($0) }
            guard reasonWords.count >= 2 else { continue }
            let hit = reasonWords.filter(answerWords.contains).count
            guard Double(hit) / Double(reasonWords.count) >= 0.6 else { continue }
            if onlyRepeatsQuestion(reasonWords, questionWords: questionWords) { continue }
            // ほぼ同じ理由の重複は1つにまとめる
            let duplicate = result.contains { existing in
                let a = Set(words(existing)), b = Set(reasonWords)
                return Double(a.intersection(b).count) / Double(max(1, min(a.count, b.count))) >= 0.8
            }
            if !duplicate { result.append(reason) }
        }
        return result
    }

    /// 質問文にない言葉が1つもなければ、質問（立場）のくり返しとみなす
    static func onlyRepeatsQuestion(_ reasonWords: [String], questionWords: Set<String>) -> Bool {
        guard !questionWords.isEmpty else { return false }
        let meaningful = reasonWords.filter { !stopWords.contains($0) && !fillers.contains($0) }
        guard !meaningful.isEmpty else { return true }
        return meaningful.allSatisfy {
            questionWords.contains($0) || questionWords.contains($0 + "s") || questionWords.contains(String($0.dropLast()))
        }
    }

    static let shortPositionSentences: Set<String> = [
        "yes", "no", "i agree", "i disagree", "i think so", "i don't think so", "yes i do", "no i don't",
        "yes i think so", "no i don't think so", "i do", "i don't",
    ]

    /// 文ごとに数えた「理由になっている文」の数（AI が理由をまとめてしまった場合の補助）。
    /// 立場だけの短い文、内容語が3語未満の文、質問のくり返しの文は数えない
    static func sentenceReasonCount(_ transcript: String, question: String) -> Int {
        let questionWords = Set(words(question))
        let sentences = transcript.split(whereSeparator: { ".!?".contains($0) })
        var count = 0
        for sentence in sentences {
            let sentenceWords = words(String(sentence)).filter { !fillers.contains($0) }
            let joined = sentenceWords.joined(separator: " ")
            if shortPositionSentences.contains(joined) { continue }
            let content = sentenceWords.filter { !stopWords.contains($0) }
            guard content.count >= 3 else { continue }
            if onlyRepeatsQuestion(sentenceWords, questionWords: questionWords) { continue }
            count += 1
        }
        return min(2, count)
    }

    /// No.3・No.4（5点）: 立場 1点 ＋ 理由（最大2つ）2点 ＋ 文法 2点（ほぼ正しい2・伝わる1・伝わりにくい0）
    static func opinionScore(positionClear: Bool, reasonCount: Int, grammarLevel: Int, contentWords: Int) -> Int {
        var score = (positionClear ? 1 : 0) + min(2, reasonCount) + max(0, min(2, grammarLevel))
        if contentWords < 8 { score = min(score, 2) }
        return min(5, score)
    }
}
