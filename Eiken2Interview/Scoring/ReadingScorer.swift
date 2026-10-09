import Foundation

/// 音読の採点（AIは使わない）。パッセージと文字起こしを単語単位で対応づける。
enum ReadingScorer {
    static let longPauseSeconds = 2.0

    static func score(passage: String, transcript: Transcript, recording: Recording?) -> ItemOutcome {
        let analysis = analyze(passage: passage, transcript: transcript, recording: recording)
        let spokenCount = transcript.wordCount

        var score: Int
        switch analysis.accuracy {
        case 0.95...: score = 5
        case 0.90...: score = 4
        case 0.80...: score = 3
        case 0.70...: score = 2
        default: score = 1
        }
        if analysis.wordsPerMinute < 80 { score -= 1 }
        if analysis.longPauses >= 3 { score -= 1 }
        score = spokenCount == 0 ? 0 : max(1, score)

        var good: [String] = []
        var improvements: [String] = []
        if spokenCount == 0 {
            improvements.append("音読が聞き取れませんでした。マイクに向かって、はっきり大きな声で読もう。")
        } else {
            if analysis.accuracy >= 0.95 { good.append("ほとんどの単語を正しく読めています。") }
            if (100...160).contains(analysis.wordsPerMinute) { good.append("ちょうどよい速さで読めています。") }

            let missed = analysis.words.filter { $0.status == .missed }.map(\.text)
            let misread = analysis.words.filter { $0.status == .misread }.map(\.text)
            if !missed.isEmpty {
                improvements.append("読み飛ばした単語があります: \(sample(missed))。1語ずつ指でなぞりながら読む練習をしよう。")
            }
            if !misread.isEmpty {
                improvements.append("うまく聞き取れなかった単語があります: \(sample(misread))。発音を確認してみよう（音声認識のミスのこともあります）。")
            }
            if analysis.wordsPerMinute < 80 {
                improvements.append("もう少しスムーズに読もう。意味のまとまりごとに区切って読むと読みやすくなります。")
            } else if analysis.wordsPerMinute > 170 {
                improvements.append("少し速すぎるかもしれません。意味のまとまりで区切って、はっきり読もう。")
            }
            if analysis.longPauses >= 3 {
                improvements.append("途中で長く止まるところがありました。黙読の20秒で、読み方が分からない単語を確認しておこう。")
            }
        }

        return ItemOutcome(
            kind: .reading,
            score: score,
            transcript: transcript.text,
            audioFiles: recording.map { [$0.relativePath] } ?? [],
            goodPoints: Array(good.prefix(2)),
            improvements: Array(improvements.prefix(2)),
            modelAnswer: passage,
            tags: [],
            reading: analysis
        )
    }

    static func analyze(passage: String, transcript: Transcript, recording: Recording?) -> ReadingAnalysis {
        let display = passage.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized = display.map(normalize)
        let spoken = transcript.text.split(whereSeparator: \.isWhitespace)
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }

        // 記号だけのトークンは判定対象から外す
        let targetIndices = normalized.indices.filter { !normalized[$0].isEmpty }
        let statuses = align(targetIndices.map { normalized[$0] }, spoken)
        var statusByIndex: [Int: ReadingAnalysis.Status] = [:]
        for (k, index) in targetIndices.enumerated() { statusByIndex[index] = statuses[k] }

        let words = display.indices.map {
            ReadingAnalysis.Word(text: display[$0], status: statusByIndex[$0] ?? .correct)
        }
        let correct = statuses.filter { $0 == .correct }.count
        let accuracy = statuses.isEmpty ? 0 : Double(correct) / Double(statuses.count)

        let span: Double
        if let first = transcript.words.first, let last = transcript.words.last, last.end > first.start {
            span = last.end - first.start
        } else if let recording {
            span = recording.duration - (recording.firstSpeechAt ?? 0)
        } else {
            span = 0
        }
        let wpm = span > 1 ? Double(spoken.count) / span * 60 : 0

        let pauses = zip(transcript.words, transcript.words.dropFirst())
            .filter { $1.start - $0.end >= longPauseSeconds }
            .count

        return ReadingAnalysis(words: words, accuracy: accuracy, wordsPerMinute: wpm, longPauses: pauses)
    }

    static func normalize(_ token: String) -> String {
        ScoringRules.normalize(token)
    }

    /// 編集距離でパッセージの各単語を「正しく読めた / 読み間違い / 読み飛ばし」に分類する
    static func align(_ target: [String], _ spoken: [String]) -> [ReadingAnalysis.Status] {
        let n = target.count, m = spoken.count
        guard n > 0 else { return [] }
        guard m > 0 else { return Array(repeating: .missed, count: n) }

        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = matches(target[i - 1], spoken[j - 1]) ? 0 : 1
                d[i][j] = min(d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }

        var result = Array(repeating: ReadingAnalysis.Status.missed, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            let cost = matches(target[i - 1], spoken[j - 1]) ? 0 : 1
            if d[i][j] == d[i - 1][j - 1] + cost {
                result[i - 1] = cost == 0 ? .correct : .misread
                i -= 1
                j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 {
                result[i - 1] = .missed
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    /// 長めの単語は1文字違いまで許す（音声認識の揺れ対策）
    private static func matches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 5 else { return false }
        return levenshtein(Array(a), Array(b)) <= 1
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j - 1] + cost, previous[j] + 1, current[j - 1] + 1)
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func sample(_ words: [String]) -> String {
        let unique = words.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let shown = unique.prefix(4).map { "“\($0.trimmingCharacters(in: .punctuationCharacters))”" }
        return shown.joined(separator: ", ") + (unique.count > 4 ? " など" : "")
    }
}
