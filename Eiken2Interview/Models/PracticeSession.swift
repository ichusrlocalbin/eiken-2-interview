import Foundation
import SwiftData

/// 練習1回分の履歴。項目ごとの詳細は JSON にまとめて保存する。
@Model
final class PracticeSession {
    var id: UUID
    var date: Date
    var mode: String
    var problemSetId: String
    var problemTitle: String
    var totalScore: Int
    var maxScore: Int = 33
    var summaryAdvice: String
    var itemsJSON: Data

    init(outcome: InterviewOutcome) {
        id = outcome.sessionID
        date = outcome.date
        mode = outcome.mode.rawValue
        maxScore = outcome.maxScore
        problemSetId = outcome.problemSetId
        problemTitle = outcome.problemTitle
        totalScore = outcome.totalScore
        summaryAdvice = outcome.summaryAdvice
        itemsJSON = (try? JSONEncoder().encode(outcome.items)) ?? Data()
    }

    var outcome: InterviewOutcome {
        InterviewOutcome(
            sessionID: id,
            date: date,
            problemSetId: problemSetId,
            problemTitle: problemTitle,
            items: items,
            summaryAdvice: summaryAdvice,
            mode: practiceMode
        )
    }

    var items: [ItemOutcome] {
        (try? JSONDecoder().decode([ItemOutcome].self, from: itemsJSON)) ?? []
    }

    var practiceMode: PracticeMode { PracticeMode(rawValue: mode) ?? .full }
}

enum RecordingStorage {
    static var root: URL {
        URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    /// `relativePath` は "<sessionID>/<name>.m4a"
    static func url(for relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    static func newURL(session: UUID, name: String) throws -> (url: URL, relativePath: String) {
        let dir = root.appending(path: session.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let relative = "\(session.uuidString)/\(name).m4a"
        return (root.appending(path: relative), relative)
    }

    static func delete(session: UUID) {
        try? FileManager.default.removeItem(at: root.appending(path: session.uuidString))
    }
}
