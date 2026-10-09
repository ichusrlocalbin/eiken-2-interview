import Charts
import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 履歴: 合計点の推移・項目別の推移・よくあるミス・全記録
struct HistoryView: View {
    @Query(sort: \PracticeSession.date) private var sessions: [PracticeSession]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedItem: ItemKind = .reading

    private var fullSessions: [PracticeSession] { sessions.filter { $0.practiceMode == .full } }

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView("まだ記録がありません", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("本番モードで練習すると、ここに点数の推移が表示されます。"))
            } else {
                Section {
                    TotalScoreChart(sessions: fullSessions)
                } header: {
                    Text("合計点の推移（本番モード）")
                } footer: {
                    Text("点線は合格の目安（\(InterviewOutcome.passLine)点）。グラフをタップすると、その回の点数が見られます。")
                }

                Section("項目別の得点率") {
                    Picker("項目", selection: $selectedItem) {
                        ForEach(ItemKind.answerItems, id: \.self) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ItemTrendChart(sessions: sessions, kind: selectedItem)
                }

                Section {
                    ItemAverageChart(sessions: sessions)
                } header: {
                    Text("項目別の平均（直近5回）")
                } footer: {
                    Text("短いバーの項目が苦手なところです。ホームの「苦手復習」で集中して練習できます。")
                }

                let mistakes = MistakeSummary.top(from: sessions)
                if !mistakes.isEmpty {
                    Section("よくあるミス") {
                        ForEach(mistakes, id: \.tag) { entry in
                            HStack {
                                Text(entry.label)
                                Spacer()
                                Text("\(entry.count) 回")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("すべての記録") {
                    ForEach(sessions.reversed()) { session in
                        NavigationLink {
                            ResultView(outcome: session.outcome)
                                .navigationTitle("結果")
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("履歴")
        .toolbar {
            if !sessions.isEmpty {
                ShareLink(item: HistoryExport(sessions: sessions.map(\.outcome)),
                          preview: SharePreview("練習の記録（\(sessions.count)回分）")) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let ordered = Array(sessions.reversed())
        for index in offsets {
            let session = ordered[index]
            RecordingStorage.delete(session: session.id)
            modelContext.delete(session)
        }
    }
}

struct SessionRow: View {
    let session: PracticeSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.problemTitle)
                    if session.practiceMode == .partial {
                        Text(session.practiceMode.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(session.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(session.totalScore) / \(session.maxScore)")
                .monospacedDigit()
                .foregroundStyle(scoreColor)
        }
    }

    private var scoreColor: Color {
        if session.practiceMode == .full {
            return session.totalScore >= InterviewOutcome.passLine ? .green : .orange
        }
        return Double(session.totalScore) / Double(max(1, session.maxScore)) >= 0.6 ? .green : .orange
    }
}

// MARK: - グラフ

/// 回数（1回目, 2回目…）を横軸にする。日付だと同じ日の練習が重なって読みにくいため
private struct TotalScoreChart: View {
    let sessions: [PracticeSession]
    @State private var selected: Int?

    var body: some View {
        if sessions.isEmpty {
            Text("本番モードの記録がまだありません")
                .foregroundStyle(.secondary)
        } else {
            let points = Array(sessions.enumerated())
            Chart {
                RuleMark(y: .value("合格の目安", InterviewOutcome.passLine))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                ForEach(points, id: \.element.id) { index, session in
                    LineMark(x: .value("回", index + 1), y: .value("合計点", session.totalScore))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("回", index + 1), y: .value("合計点", session.totalScore))
                        .symbolSize(60)
                }
                if let selected, points.indices.contains(selected - 1) {
                    let session = points[selected - 1].element
                    RuleMark(x: .value("回", selected))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            VStack(spacing: 2) {
                                Text("\(selected)回目 \(session.totalScore)点")
                                    .font(.caption.weight(.semibold))
                                Text(session.problemTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(6)
                            .background(.background, in: .rect(cornerRadius: 6))
                            .shadow(radius: 1)
                        }
                }
            }
            .chartYScale(domain: 0...InterviewOutcome.fullMaxScore)
            .chartXScale(domain: 0.5...Double(max(points.count, 2)) + 0.5)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(points.count, 6))) }
            .chartXSelection(value: $selected)
            .frame(height: 200)
            .padding(.vertical, 8)
        }
    }
}

private struct ItemTrendChart: View {
    let sessions: [PracticeSession]
    let kind: ItemKind

    var body: some View {
        let points = sessions.compactMap { session -> (date: Date, percent: Int)? in
            guard let item = session.items.first(where: { $0.kind == kind }) else { return nil }
            return (session.date, Int((item.ratio * 100).rounded()))
        }
        if points.isEmpty {
            Text("\(kind.shortTitle) の記録がまだありません")
                .foregroundStyle(.secondary)
        } else {
            Chart(Array(points.enumerated()), id: \.offset) { index, point in
                LineMark(x: .value("回", index + 1), y: .value("得点率", point.percent))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("回", index + 1), y: .value("得点率", point.percent))
                    .symbolSize(60)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1)) }
            .chartXScale(domain: 0.5...Double(max(points.count, 2)) + 0.5)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(points.count, 6))) }
            .frame(height: 160)
            .padding(.vertical, 8)
        }
    }
}

private struct ItemAverageChart: View {
    let sessions: [PracticeSession]

    var body: some View {
        let averages = ItemKind.answerItems.compactMap { kind -> (kind: ItemKind, percent: Int)? in
            let ratios = sessions.reversed()
                .compactMap { $0.items.first(where: { $0.kind == kind })?.ratio }
                .prefix(5)
            guard !ratios.isEmpty else { return nil }
            return (kind, Int((ratios.reduce(0, +) / Double(ratios.count) * 100).rounded()))
        }
        Chart(averages, id: \.kind) { entry in
            BarMark(x: .value("平均", entry.percent), y: .value("項目", entry.kind.shortTitle))
                .clipShape(.rect(cornerRadius: 4))
                .annotation(position: .trailing) {
                    Text("\(entry.percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: 0...110)
        .chartXAxis(.hidden)
        .frame(height: CGFloat(averages.count) * 36)
        .padding(.vertical, 8)
    }
}

// MARK: - よくあるミス

enum MistakeSummary {
    struct Entry {
        let tag: String
        let label: String
        let count: Int
    }

    static func top(from sessions: [PracticeSession], limit: Int = 5) -> [Entry] {
        var counts: [String: Int] = [:]
        for session in sessions {
            for item in session.items {
                for tag in item.tags { counts[tag, default: 0] += 1 }
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { Entry(tag: $0.key, label: MistakeTag(rawValue: $0.key)?.label ?? $0.key, count: $0.value) }
    }
}

// MARK: - 書き出し

/// 採点の調整用に、文字起こし・点数・フィードバックを JSON で書き出す（録音は含まない）
struct HistoryExport: Transferable {
    let sessions: [InterviewOutcome]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { export in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(export.sessions)
        }
        .suggestedFileName("eiken2-history.json")
    }
}
