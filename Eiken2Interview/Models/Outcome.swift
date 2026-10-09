import Foundation

enum ItemKind: String, Codable, CaseIterable, Hashable {
    case reading, no1, no2, no3, no4, attitude

    var title: String {
        switch self {
        case .reading: "音読"
        case .no1: "No.1 パッセージの質問"
        case .no2: "No.2 イラストの説明"
        case .no3: "No.3 あなたの意見"
        case .no4: "No.4 あなたの意見"
        case .attitude: "アティチュード（態度）"
        }
    }

    var shortTitle: String {
        switch self {
        case .reading: "音読"
        case .no1: "No.1"
        case .no2: "No.2"
        case .no3: "No.3"
        case .no4: "No.4"
        case .attitude: "態度"
        }
    }

    var maxScore: Int {
        switch self {
        case .no2: 10
        case .attitude: 3
        default: 5
        }
    }

    /// 面接で答える項目（アティチュード以外）
    static let answerItems: [ItemKind] = [.reading, .no1, .no2, .no3, .no4]
}

enum PracticeMode: String, Codable {
    /// 本番モード（あいさつから No.4 まで通し）
    case full
    /// 苦手復習（一部の項目だけ）
    case partial
    /// 特訓モード（1つの項目をヒント付きで練習）
    case drill

    var label: String {
        switch self {
        case .full: "本番"
        case .partial: "復習"
        case .drill: "特訓"
        }
    }
}

/// 音読の単語ごとの判定結果
struct ReadingAnalysis: Codable, Hashable {
    enum Status: String, Codable {
        case correct, misread, missed
    }

    struct Word: Codable, Hashable {
        let text: String
        let status: Status
    }

    let words: [Word]
    let accuracy: Double
    let wordsPerMinute: Double
    let longPauses: Int
}

struct ItemOutcome: Codable, Hashable, Identifiable {
    var id: ItemKind { kind }

    let kind: ItemKind
    let score: Int
    let transcript: String
    let audioFiles: [String]
    let goodPoints: [String]
    let improvements: [String]
    let modelAnswer: String?
    let tags: [String]
    var reading: ReadingAnalysis? = nil
    /// 面接官が聞いた内容（結果画面で表示・再生する）
    var question: String? = nil
    /// AIを使えず目安の点数になった場合 true
    var isEstimated: Bool = false
    /// 受験者の回答の文法を直した英文（AI による言い直し）
    var correctedAnswer: String? = nil
    /// AI の採点に失敗したときの理由（原因調査用）
    var scoringError: String? = nil

    var ratio: Double { Double(score) / Double(kind.maxScore) }
}

struct InterviewOutcome: Codable, Hashable {
    let sessionID: UUID
    let date: Date
    let problemSetId: String
    let problemTitle: String
    let items: [ItemOutcome]
    let summaryAdvice: String
    var mode: PracticeMode = .full

    var totalScore: Int { items.reduce(0) { $0 + $1.score } }
    var maxScore: Int { items.reduce(0) { $0 + $1.kind.maxScore } }
    static let fullMaxScore = ItemKind.allCases.reduce(0) { $0 + $1.maxScore }
    static let passLine = 21
}
