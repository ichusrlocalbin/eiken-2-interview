import SwiftData
import SwiftUI

struct InterviewView: View {
    @State private var session: InterviewSession
    @State private var confirmQuit = false
    @State private var savedSessionID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    init(problem: ProblemSet, items: Set<ItemKind> = Set(ItemKind.allCases), mode: PracticeMode? = nil, showsHints: Bool = false) {
        _session = State(initialValue: InterviewSession(problem: problem, items: items, mode: mode, showsHints: showsHints))
    }

    /// 同じ設定で、同じ問題（または別の問題）をもう一度
    private func restart(with problem: ProblemSet) {
        session = InterviewSession(problem: problem, items: session.items, mode: session.mode, showsHints: session.showsHints)
    }

    private func anotherProblem() -> ProblemSet {
        let others = ProblemStore.loadAll().filter { $0.id != session.problem.id }
        return others.randomElement() ?? session.problem
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(session.phase.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if session.phase == .finished {
                            Button("閉じる") { dismiss() }
                        } else {
                            Button(role: .destructive) {
                                session.pause()
                                confirmQuit = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark")
                                    Text("やめる")
                                }
                                .fontWeight(.semibold)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    if session.phase == .finished {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button {
                                    restart(with: session.problem)
                                } label: {
                                    Label("同じ問題でもう一度", systemImage: "arrow.counterclockwise")
                                }
                                Button {
                                    restart(with: anotherProblem())
                                } label: {
                                    Label("別の問題で", systemImage: "shuffle")
                                }
                            } label: {
                                Label("もう一度", systemImage: "arrow.counterclockwise")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
                .alert("練習をやめますか？", isPresented: $confirmQuit) {
                    Button("やめる", role: .destructive) {
                        session.abort()
                        dismiss()
                    }
                    Button("続ける", role: .cancel) {
                        session.resume()
                    }
                } message: {
                    Text("やめると、今回の記録は残りません。")
                }
        }
        .onAppear { StartupTimer.mark("面接画面の表示") }
        .task(id: session.sessionID) {
            StartupTimer.mark("task 開始")
            await session.run()
        }
        .onChange(of: session.outcome) { _, outcome in
            guard let outcome, savedSessionID != outcome.sessionID else { return }
            modelContext.insert(PracticeSession(outcome: outcome))
            savedSessionID = outcome.sessionID
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .finished:
            if let outcome = session.outcome {
                ResultView(outcome: outcome)
            }
        case .scoring:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(session.scoringMessage)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView("練習を始められませんでした", systemImage: "exclamationmark.triangle", description: Text(message))
        default:
            InterviewStageView(session: session)
        }
    }
}

private struct InterviewStageView: View {
    let session: InterviewSession

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(steps: session.steps, current: session.phase)
                .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if session.phase.showsCard {
                            ProblemCardView(
                                problem: session.problem,
                                dimPassage: session.phase.focusesIllustration,
                                highlightsCue: session.showsHints && session.items.contains(.no1) && !session.items.contains(.reading)
                            )
                        } else if session.phase == .preparing {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .controlSize(.large)
                                Text("面接の準備をしています…")
                                    .font(.headline)
                                Text("マイクと音声認識を準備しています。少し待ってね。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 320)
                        } else if session.phase == .greeting {
                            Color.clear.frame(height: 40)
                        } else {
                            CardTurnedOverView()
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: session.phase) { _, phase in
                    if phase.focusesIllustration {
                        withAnimation { proxy.scrollTo("illustration", anchor: .top) }
                    }
                }
            }

            VStack(spacing: 12) {
                if let hint = session.hint {
                    Label(hint, systemImage: "lightbulb.fill")
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.18), in: .rect(cornerRadius: 10))
                }
                controls
            }
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if session.phase == .preparing {
            Color.clear.frame(height: 96)
        } else if let countdown = session.countdown {
            VStack(spacing: 4) {
                Text("\(countdown)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text(session.phase == .silentReading ? "黙読しよう" : "話す内容を考えよう")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 96)
            .animation(.default, value: countdown)
        } else if session.isRepeatingQuestion {
            VStack(spacing: 8) {
                Label("聞き返しを受け付けました", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("面接官がもう一度言います。よく聞こう")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 96)
        } else if session.isListening {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    ProgressView(value: session.level)
                        .tint(.red)
                    if let remaining = session.listenRemaining {
                        Text("残り\(remaining)秒")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    session.finishAnswer()
                } label: {
                    Group {
                        if session.isCheckingAnswer {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("確認中…")
                            }
                        } else {
                            Label("回答おわり", systemImage: "checkmark")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(session.isCheckingAnswer)
            }
            .frame(height: 96)
        } else {
            // 本番と同じく、面接官のセリフは文字で表示せず耳で聞き取る
            VStack(spacing: 8) {
                Image(systemName: "person.wave.2.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor, isActive: session.isSpeaking)
                Text("面接官の話をよく聞こう")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 96)
        }
    }
}

private struct StepIndicator: View {
    let steps: [InterviewSession.Phase]
    let current: InterviewSession.Phase

    var body: some View {
        let currentIndex = steps.firstIndex(of: current) ?? (current == .closing ? steps.count : -1)
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= currentIndex ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal)
    }
}
