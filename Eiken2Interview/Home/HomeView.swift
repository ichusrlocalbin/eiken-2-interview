import FoundationModels
import SwiftData
import SwiftUI

/// 面接画面を開くときの指定（問題と練習する項目）
struct InterviewLaunch: Identifiable {
    let id = UUID()
    let problem: ProblemSet
    var items: Set<ItemKind> = Set(ItemKind.allCases)
    var mode: PracticeMode? = nil
    var showsHints = false
}

struct HomeView: View {
    @Query(sort: \PracticeSession.date, order: .reverse) private var sessions: [PracticeSession]
    @State private var problems = ProblemStore.loadAll()
    @State private var launch: InterviewLaunch?
    @State private var showPicker = false
    @State private var showSettings = false

    private var lastFull: PracticeSession? { sessions.first { $0.practiceMode == .full } }
    private var weakCount: Int { WeakPoints.entries(problems: problems, sessions: sessions).count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StatusBanner()

                    MainCard(
                        lastFull: lastFull,
                        disabled: problems.isEmpty,
                        onStart: {
                            StartupTimer.begin()
                            if let problem = randomProblem() { launch = InterviewLaunch(problem: problem) }
                        },
                        onPick: { showPicker = true }
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(lastFull == nil ? "慣れてきたら" : "次はこれ")
                        HStack(spacing: 12) {
                            NavigationLink {
                                ReviewView(problems: problems) { problem, items in
                                    launch = InterviewLaunch(problem: problem, items: items)
                                }
                            } label: {
                                Tile(title: "苦手復習", icon: "arrow.counterclockwise.circle.fill", tint: .orange,
                                     detail: weakCount > 0 ? "\(weakCount) 問あります" : "苦手はまだなし",
                                     badge: weakCount)
                            }
                            NavigationLink {
                                DrillView(problems: problems) { launch = $0 }
                            } label: {
                                Tile(title: "特訓モード", icon: "figure.run.circle.fill", tint: .purple,
                                     detail: "1つずつヒント付き", badge: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("記録と問題")
                        VStack(spacing: 0) {
                            NavigationLink {
                                HistoryView()
                            } label: {
                                Row(title: "履歴とグラフ", icon: "chart.line.uptrend.xyaxis", trailing: sessions.isEmpty ? nil : "\(sessions.count) 回")
                            }
                            Divider().padding(.leading, 52)
                            NavigationLink {
                                ProblemManagerView { problems = ProblemStore.loadAll() }
                            } label: {
                                Row(title: "問題の管理", icon: "tray.full", trailing: "\(problems.count) 問")
                            }
                        }
                        .buttonStyle(.plain)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                    }

                    if !sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("最近の結果")
                            VStack(spacing: 0) {
                                ForEach(Array(sessions.prefix(3).enumerated()), id: \.element.id) { index, session in
                                    if index > 0 { Divider().padding(.leading, 16) }
                                    NavigationLink {
                                        ResultView(outcome: session.outcome)
                                            .navigationTitle("結果")
                                    } label: {
                                        HStack {
                                            SessionRow(session: session)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear { AudioSessionConfig.activateForInterview() }
            .navigationTitle("英検2級 面接練習")
            .toolbar {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .sheet(isPresented: $showPicker) {
                ProblemPickerView(problems: problems, sessions: sessions) { problem in
                    showPicker = false
                    launch = InterviewLaunch(problem: problem)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fullScreenCover(item: $launch) { launch in
                InterviewView(problem: launch.problem, items: launch.items, mode: launch.mode, showsHints: launch.showsHints)
            }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-openInterview"), let first = problems.first {
                    // ホーム画面を少し見てから開始ボタンを押した状況にする
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        StartupTimer.begin()
                        launch = InterviewLaunch(problem: first)
                    }
                }
            }
            #endif
        }
    }

    /// まだ本番モードでやっていない問題を優先して選ぶ
    private func randomProblem() -> ProblemSet? {
        let done = Set(sessions.filter { $0.practiceMode == .full }.map(\.problemSetId))
        let fresh = problems.filter { !done.contains($0.id) }
        return (fresh.isEmpty ? problems : fresh).randomElement()
    }
}

// MARK: - 部品

/// 一番目立たせる「本番モード」のカード
private struct MainCard: View {
    let lastFull: PracticeSession?
    let disabled: Bool
    let onStart: () -> Void
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(lastFull == nil ? "まずはここから" : "今日の練習")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.white.opacity(0.25), in: .capsule)

            VStack(alignment: .leading, spacing: 6) {
                Text("本番モード")
                    .font(.largeTitle.bold())
                Text("あいさつ → 黙読20秒 → 音読 → No.1〜4 を、本番と同じ流れで練習します（約7分）")
                    .font(.subheadline)
                    .opacity(0.9)
            }

            if let lastFull {
                HStack(spacing: 6) {
                    Image(systemName: lastFull.totalScore >= InterviewOutcome.passLine ? "checkmark.seal.fill" : "flag.fill")
                    Text("前回 \(lastFull.totalScore) / \(lastFull.maxScore) 点")
                        .fontWeight(.semibold)
                    Text(lastFull.totalScore >= InterviewOutcome.passLine
                         ? "（合格ライン達成）"
                         : "（合格ラインまで あと \(InterviewOutcome.passLine - lastFull.totalScore) 点）")
                }
                .font(.subheadline)
            }

            Button(action: onStart) {
                Label("はじめる", systemImage: "play.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(Color.accentColor)
            .controlSize(.large)
            .disabled(disabled)

            Button(action: onPick) {
                Text("問題を選んで始める")
                    .font(.subheadline.weight(.semibold))
                    .underline()
                    .frame(maxWidth: .infinity)
            }
            .disabled(disabled)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.95), Color(red: 0.07, green: 0.25, blue: 0.68)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 22)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

private struct Tile: View {
    let title: String
    let icon: String
    let tint: Color
    let detail: String
    let badge: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(tint)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(tint, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}

private struct Row: View {
    let title: String
    let icon: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            if let trailing {
                Text(trailing).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// AI採点・音声認識の状態。問題がなければ1行だけ、問題があれば目立つように表示する
private struct StatusBanner: View {
    @State private var speechReady: Bool?
    @State private var speechError: String?

    var body: some View {
        let ai = SystemLanguageModel.default.availability
        let aiProblem: String? = {
            if case .unavailable(let reason) = ai { return "AI採点が使えません（\(describe(reason))）" }
            return nil
        }()
        let speechProblem: String? = speechReady == false ? "音声認識: \(speechError ?? "準備に失敗しました")" : nil

        Group {
            if aiProblem != nil || speechProblem != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([aiProblem, speechProblem].compactMap { $0 }, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
            } else if speechReady == nil {
                Label("準備しています…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("準備OK（AI採点・音声認識）", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.leading, 4)
        .task {
            InterviewerVoice.warmUp()
            do {
                try await Transcriber.prepare()
                speechReady = true
            } catch {
                speechError = error.localizedDescription
                speechReady = false
            }
        }
    }

    private func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "この端末は非対応"
        case .appleIntelligenceNotEnabled: "設定で Apple Intelligence をオンにしてください"
        case .modelNotReady: "モデルをダウンロード中です"
        @unknown default: "不明な理由"
        }
    }
}

private struct ProblemPickerView: View {
    let problems: [ProblemSet]
    let sessions: [PracticeSession]
    let onSelect: (ProblemSet) -> Void

    var body: some View {
        NavigationStack {
            List(problems) { problem in
                Button {
                    onSelect(problem)
                } label: {
                    HStack {
                        Text(problem.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if let best = bestScore(problem.id) {
                            Text("ベスト \(best)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("問題を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func bestScore(_ id: String) -> Int? {
        sessions.filter { $0.problemSetId == id && $0.practiceMode == .full }.map(\.totalScore).max()
    }
}

private struct SettingsView: View {
    @AppStorage(AppSettings.speechRateKey) private var speechRate = 0.45
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Slider(value: $speechRate, in: 0.35...0.55) {
                        Text("読み上げ速度")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    }
                    Button("試しに聞く") {
                        Task { await InterviewerVoice().speak("No. 1. According to the passage, how can people save time?", rate: Float(speechRate)) }
                    }
                } header: {
                    Text("面接官の読み上げ速度")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完了") { dismiss() }
            }
        }
    }
}
