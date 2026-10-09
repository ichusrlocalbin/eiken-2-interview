import SwiftData
import SwiftUI

/// 苦手復習: 問題ごとに、最新の得点率が 60% 未満の項目だけをもう一度練習する
struct ReviewView: View {
    let problems: [ProblemSet]
    let onStart: (ProblemSet, Set<ItemKind>) -> Void
    @Query(sort: \PracticeSession.date, order: .reverse) private var sessions: [PracticeSession]

    var body: some View {
        let entries = WeakPoints.entries(problems: problems, sessions: sessions)
        List {
            if entries.isEmpty {
                ContentUnavailableView("苦手な項目はありません", systemImage: "checkmark.seal",
                                       description: Text("得点率が60%未満だった項目が、ここに表示されます。"))
            } else {
                Section {
                    ForEach(entries, id: \.problem.id) { entry in
                        Button {
                            onStart(entry.problem, Set(entry.weak.map(\.kind)))
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.problem.title)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    ForEach(entry.weak, id: \.kind) { weak in
                                        Text("\(weak.kind.shortTitle) \(Int(weak.ratio * 100))%")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.orange.opacity(0.15), in: .capsule)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    Text("タップすると、苦手な項目だけを本番と同じ形で練習します。60%以上取れたら、リストから消えます。")
                }
            }
        }
        .navigationTitle("苦手復習")
    }
}

enum WeakPoints {
    struct Weak {
        let kind: ItemKind
        let ratio: Double
    }

    struct Entry {
        let problem: ProblemSet
        let weak: [Weak]
        let lastDate: Date
    }

    static let threshold = 0.6

    /// `sessions` は新しい順で渡す
    static func entries(problems: [ProblemSet], sessions: [PracticeSession]) -> [Entry] {
        let byID = Dictionary(uniqueKeysWithValues: problems.map { ($0.id, $0) })
        var latest: [String: [ItemKind: (ratio: Double, date: Date)]] = [:]
        for session in sessions {
            for item in session.items where ItemKind.answerItems.contains(item.kind) {
                if latest[session.problemSetId]?[item.kind] == nil {
                    latest[session.problemSetId, default: [:]][item.kind] = (item.ratio, session.date)
                }
            }
        }
        return latest.compactMap { id, items -> Entry? in
            guard let problem = byID[id] else { return nil }
            let weak = ItemKind.answerItems.compactMap { kind -> Weak? in
                guard let result = items[kind], result.ratio < threshold else { return nil }
                return Weak(kind: kind, ratio: result.ratio)
            }
            guard !weak.isEmpty else { return nil }
            let lastDate = weak.compactMap { items[$0.kind]?.date }.max() ?? .distantPast
            return Entry(problem: problem, weak: weak, lastDate: lastDate)
        }
        .sorted { $0.lastDate > $1.lastDate }
    }
}
