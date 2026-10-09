import SwiftData
import SwiftUI

/// 特訓モード: 1つの項目だけを、ヒント付きで練習する
struct DrillView: View {
    let problems: [ProblemSet]
    let onStart: (InterviewLaunch) -> Void
    @Query(sort: \PracticeSession.date, order: .reverse) private var sessions: [PracticeSession]
    @AppStorage("drillShowsHints") private var showsHints = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $showsHints) {
                    Label("ヒントを表示する", systemImage: "lightbulb")
                }
            } footer: {
                Text("慣れてきたらヒントをオフにして、本番と同じ状態で練習しよう。")
            }

            ForEach(Drill.allCases) { drill in
                Section {
                    Button {
                        if let problem = pick(for: drill) { start(drill, problem) }
                    } label: {
                        Label("おまかせで始める", systemImage: "play.circle.fill")
                    }
                    .disabled(problems.isEmpty)
                    NavigationLink {
                        List(problems) { problem in
                            Button {
                                start(drill, problem)
                            } label: {
                                HStack {
                                    Text(problem.title).foregroundStyle(.primary)
                                    Spacer()
                                    if let best = best(drill, problem) {
                                        Text("ベスト \(Int(best * 100))%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .navigationTitle(drill.title)
                    } label: {
                        Label("問題を選ぶ", systemImage: "list.bullet")
                    }
                } header: {
                    Label(drill.title, systemImage: drill.icon)
                } footer: {
                    Text(drill.detail)
                }
            }
        }
        .navigationTitle("特訓モード")
    }

    private func start(_ drill: Drill, _ problem: ProblemSet) {
        onStart(InterviewLaunch(problem: problem, items: drill.items, mode: .drill, showsHints: showsHints))
    }

    /// その項目の練習回数が少ない問題を優先する
    private func pick(for drill: Drill) -> ProblemSet? {
        let counts = Dictionary(grouping: sessions.filter { session in
            session.items.contains { drill.items.contains($0.kind) }
        }, by: \.problemSetId).mapValues(\.count)
        let fewest = problems.map { counts[$0.id] ?? 0 }.min() ?? 0
        return problems.filter { (counts[$0.id] ?? 0) == fewest }.randomElement()
    }

    private func best(_ drill: Drill, _ problem: ProblemSet) -> Double? {
        sessions.filter { $0.problemSetId == problem.id }
            .flatMap { $0.items.filter { drill.items.contains($0.kind) } }
            .map(\.ratio)
            .max()
    }
}

enum Drill: String, CaseIterable, Identifiable {
    case reading, no1, no2, opinion

    var id: String { rawValue }

    var items: Set<ItemKind> {
        switch self {
        case .reading: [.reading]
        case .no1: [.no1]
        case .no2: [.no2]
        case .opinion: [.no3, .no4]
        }
    }

    var title: String {
        switch self {
        case .reading: "音読"
        case .no1: "No.1 パッセージの質問"
        case .no2: "No.2 イラストの説明"
        case .opinion: "No.3・No.4 自分の意見"
        }
    }

    var icon: String {
        switch self {
        case .reading: "text.book.closed"
        case .no1: "questionmark.bubble"
        case .no2: "photo.on.rectangle"
        case .opinion: "person.wave.2"
        }
    }

    var detail: String {
        switch self {
        case .reading: "黙読20秒 → お手本を聞く（ヒントがオンのとき）→ 音読。読み飛ばした単語と読む速さをチェックします。"
        case .no1: "黙読20秒 → No.1。ヒントがオンのときは、答えの手がかりになる文を黄色で示します。"
        case .no2: "準備20秒 → 3コマの説明。時制やセリフの伝え方のヒントを表示します。"
        case .opinion: "カードなしで No.3 と No.4 に答えます。ヒントがオンのときは、答えの型を表示します。"
        }
    }
}
