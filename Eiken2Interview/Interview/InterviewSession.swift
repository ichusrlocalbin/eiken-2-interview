import AVFoundation
import Foundation
import Observation

/// 本番モードの進行役。面接官のセリフ → タイマー → 録音 を順番に実行し、最後に採点する。
@MainActor
@Observable
final class InterviewSession {
    enum Phase: Equatable {
        case preparing, greeting, silentReading, readingAloud, no1, no2Prep, no2, no3, no4, closing
        case scoring, finished, failed(String)

        var title: String {
            switch self {
            case .preparing: "準備中"
            case .greeting: "あいさつ"
            case .silentReading: "黙読"
            case .readingAloud: "音読"
            case .no1: "No.1"
            case .no2Prep: "No.2 準備"
            case .no2: "No.2"
            case .no3: "No.3"
            case .no4: "No.4"
            case .closing: "終了"
            case .scoring: "採点中"
            case .finished: "結果"
            case .failed: "エラー"
            }
        }

        var showsCard: Bool {
            switch self {
            case .silentReading, .readingAloud, .no1, .no2Prep, .no2: true
            default: false
            }
        }

        var focusesIllustration: Bool { self == .no2Prep || self == .no2 }
    }

    let problem: ProblemSet
    let sessionID = UUID()
    /// 練習する項目。本番モードはアティチュードを含む全項目
    let items: Set<ItemKind>
    let mode: PracticeMode
    /// 特訓モードでヒントを表示するか
    let showsHints: Bool

    private(set) var phase: Phase = .preparing
    private(set) var isSpeaking = false
    private(set) var countdown: Int?
    private(set) var isListening = false
    private(set) var listenRemaining: Int?
    /// 0...1 のマイク音量（表示用）
    private(set) var level: Double = 0
    private(set) var scoringMessage = ""
    /// 「やめる」の確認中は一時停止する
    private(set) var isPaused = false
    /// 「回答おわり」を押したあと、聞き返しかどうかを確かめている間 true
    private(set) var isCheckingAnswer = false
    /// 聞き返しを受け付けて、面接官が言い直している間 true
    private(set) var isRepeatingQuestion = false
    private(set) var outcome: InterviewOutcome?

    private let voice = InterviewerVoice.shared
    private let recorder = AnswerRecorder()
    private var stopRequested = false
    private var reprompts = 0
    /// 受験者が聞き返した回数（面接全体）
    private var pardons = 0
    private var recordings: [AnswerKey: Recording] = [:]
    private var transcriptTasks: [AnswerKey: Task<Transcript, Never>] = [:]
    private var lastTranscriptTask: Task<Transcript, Never>?

    init(problem: ProblemSet, items: Set<ItemKind> = Set(ItemKind.allCases), mode: PracticeMode? = nil, showsHints: Bool = false) {
        self.problem = problem
        self.items = items
        self.mode = items == Set(ItemKind.allCases) ? .full : (mode ?? .partial)
        self.showsHints = showsHints && self.mode != .full
    }

    /// 今のステップで表示するヒント（特訓モードでヒントがオンのとき）
    var hint: String? {
        guard showsHints else { return nil }
        switch phase {
        case .silentReading where items.contains(.no1) && !items.contains(.reading):
            return "黄色の文に注目。No.1 の答えは “by doing so” や “in this way” の前に書かれていることが多いよ。"
        case .silentReading, .readingAloud:
            return "コンマやピリオドで一息。意味のまとまりで区切って、はっきり読もう。タイトルも読むよ。"
        case .no1:
            return "黄色の文から答えを探そう。主語を They / He / She などに変えて、“By ~ing.” か “They ~.” の形で答えると◎"
        case .no2Prep, .no2:
            return "最初の文から始めて、各コマ2文くらい。過去形・過去進行形（was / were + ~ing）で話そう。セリフは “〇〇 said to ~, \"...\"” で伝えよう。"
        case .no3:
            return "型: “I agree. / I disagree.” → 理由1（Because ...）→ 理由2（Also, ...）。聞き取れなかったら “Pardon?” と聞き返してOK。"
        case .no4:
            return "まず “Yes.” か “No.” だけ答えよう。“Why?” と聞かれたら理由を2つ（First, ... Also, ...）"
        default:
            return nil
        }
    }

    /// 進み具合の表示に使うステップ
    var steps: [Phase] {
        var steps: [Phase] = []
        if mode == .full { steps.append(.greeting) }
        if needsPassage { steps.append(.silentReading) }
        if items.contains(.reading) { steps.append(.readingAloud) }
        if items.contains(.no1) { steps.append(.no1) }
        if items.contains(.no2) { steps += [.no2Prep, .no2] }
        if items.contains(.no3) { steps.append(.no3) }
        if items.contains(.no4) { steps.append(.no4) }
        return steps
    }

    /// 黙読が必要か（音読か No.1 を練習するとき）
    private var needsPassage: Bool { items.contains(.reading) || items.contains(.no1) }

    // MARK: - 操作

    func run() async {
        do {
            try await prepare()
            try await interview()
            await score()
        } catch is CancellationError {
            abort()
        } catch {
            abort()
            phase = .failed(error.localizedDescription)
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        voice.pause()
        recorder.pause()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        voice.resume()
        recorder.resume()
    }

    /// 一時停止中はここで待つ
    private func waitWhilePaused() async throws {
        while isPaused {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 「回答おわり」ボタン
    func finishAnswer() {
        stopRequested = true
    }

    func abort() {
        _ = recorder.stop()
        voice.stop()
        transcriptTasks.values.forEach { $0.cancel() }
        if outcome == nil { RecordingStorage.delete(session: sessionID) }
    }

    // MARK: - 面接の流れ

    private func prepare() async throws {
        StartupTimer.mark("prepare 開始")
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SessionError.microphoneDenied
        }
        StartupTimer.mark("マイク許可")
        if let error = AudioSessionConfig.activateForInterview() { throw error }
        StartupTimer.mark("音声設定")
        // 音声認識の準備は読み上げと並行して進める（文字起こしの前に Transcriber 側で完了を待つ）
        Task { try? await Transcriber.prepare() }
    }

    private func interview() async throws {
        let p = problem

        if mode == .full {
            phase = .greeting
            try await say(InterviewScript.greeting)
            try await listen(.greeting, max: 10, endAfterSilence: 2, repeatable: "How are you today?")
            try await say("Thank you. Here is your card.")
        } else if needsPassage || items.contains(.no2) {
            try await say("Let's practice. Here is your card.")
        } else {
            try await say("Let's practice. Please listen carefully.")
        }

        if needsPassage {
            phase = .silentReading
            try await say(InterviewScript.readSilently)
            try await runCountdown(20)
        }

        if items.contains(.reading), showsHints {
            try await say("Let's listen to a model reading first.")
            try await say("\(problem.title). \(problem.passage)", rate: AppSettings.speechRate * 0.95)
        }

        if items.contains(.reading) {
            phase = .readingAloud
            try await say(InterviewScript.readAloud)
            try await listen(.reading, max: 70, endAfterSilence: 10)
        }

        let questionCount = [ItemKind.no1, .no2, .no3, .no4].filter(items.contains).count
        if questionCount > 0 {
            let words = ["a question", "two questions", "three questions", "four questions"]
            try await say("Now, I'll ask you \(words[questionCount - 1]).")
        }

        if items.contains(.no1) {
            phase = .no1
            try await ask(.no1, InterviewScript.no1(p), max: 40)
        }

        if items.contains(.no2) {
            phase = .no2Prep
            try await say(InterviewScript.no2)
            try await runCountdown(20)

            phase = .no2
            try await say("All right. Please begin.")
            try await listen(.no2, max: 90, reprompt: "Please begin your story with the sentence on the card.")
        }

        if items.contains(.no3) || items.contains(.no4) {
            if needsPassage || items.contains(.no2) {
                try await say("Now, please turn over the card and put it down.")
            }
        }

        if items.contains(.no3) {
            phase = .no3
            try await ask(.no3, InterviewScript.no3(p), max: 50)
        }

        if items.contains(.no4) {
            phase = .no4
            try await ask(.no4, InterviewScript.no4(p), max: 40)
            let first = await transcriptTasks[.no4]?.value ?? .empty
            let followUp = InterviewScript.no4FollowUp(first.text)
            try await ask(.no4Why, followUp, max: 40)
        }

        phase = .closing
        if mode == .full {
            try await say("Thank you. This is the end of the test. Could I have the card back, please?")
        } else {
            try await say("Thank you. That's all for today's practice.")
        }
    }

    private func score() async {
        phase = .scoring
        scoringMessage = "回答を文字に起こしています…"
        var transcripts: [AnswerKey: Transcript] = [:]
        for (key, task) in transcriptTasks {
            transcripts[key] = await task.value
        }
        let scorer = InterviewScorer(problem: problem, recordings: recordings, transcripts: transcripts, reprompts: reprompts, pardons: pardons, items: items)
        let results = await scorer.score { [weak self] message in self?.scoringMessage = message }
        outcome = InterviewOutcome(
            sessionID: sessionID,
            date: .now,
            problemSetId: problem.id,
            problemTitle: problem.title,
            items: results,
            summaryAdvice: InterviewScorer.summaryAdvice(results),
            mode: mode
        )
        phase = .finished
    }

    // MARK: - 部品

    private func say(_ text: String, rate: Float = AppSettings.speechRate) async throws {
        isSpeaking = true
        await voice.speak(text, rate: rate)
        isSpeaking = false
        try Task.checkCancellation()
        try await waitWhilePaused()
    }

    private func ask(_ key: AnswerKey, _ question: String, max: Int) async throws {
        try await say(question)
        try await listen(key, max: max, reprompt: "I'm sorry. Let me ask you again. \(question)", repeatable: question)
    }

    private func runCountdown(_ seconds: Int) async throws {
        for remaining in stride(from: seconds, to: 0, by: -1) {
            countdown = remaining
            try await Task.sleep(for: .seconds(1))
            try await waitWhilePaused()
        }
        countdown = nil
    }

    /// 回答を録音する。「回答おわり」・最大時間・話し終わったあとの無音のどれかで終了する。
    /// `reprompt` があれば、話し始めないまま6秒たったときに一度だけ聞き直す。
    /// `repeatable` があれば、受験者が “Pardon?” などと聞き返したときに質問を言い直す（同じ質問は2回まで）
    private func listen(_ key: AnswerKey, max: Int, endAfterSilence: Double = 8, reprompt: String? = nil, repeatable: String? = nil) async throws {
        let (url, relativePath) = try RecordingStorage.newURL(session: sessionID, name: key.rawValue)
        var canReprompt = reprompt != nil
        var repeatsForThisQuestion = 0

        while true {
            stopRequested = false
            let live = repeatable != nil ? LiveTranscriber.makeIfAvailable() : nil
            if let live {
                live.start(inputFormat: recorder.inputFormat)
                try recorder.start(url: url, relativePath: relativePath) { live.feed($0) }
            } else {
                try recorder.start(url: url, relativePath: relativePath)
            }
            isListening = true
            var shouldReprompt = false
            var askedToRepeat = false
            /// 「回答おわり」を押したとき、話した時間が短ければ録音ファイルで聞き返しかを確かめる
            var checkFileForPardon = false

            do {
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    try await waitWhilePaused()
                    let snap = recorder.snapshot()
                    level = Swift.max(0, Swift.min(1, Double(snap.level + 60) / 60))
                    listenRemaining = Swift.max(0, max - Int(snap.elapsed))
                    if stopRequested {
                        if repeatable != nil {
                            let liveText = live?.text ?? ""
                            NSLog("[Pardon] ボタン: live='%@'", liveText)
                            if PardonDetector.isPardon(liveText) {
                                askedToRepeat = true
                            } else if ScoringRules.contentWordCount(liveText) <= PardonDetector.maxWords {
                                // リアルタイムの文字起こしは遅れることがあるので、録音ファイルで確かめる（0.1秒ほど）
                                checkFileForPardon = true
                            }
                        }
                        break
                    }
                    if snap.elapsed >= Double(max) { break }
                    // 短く「Pardon?」と言って黙ったら、質問を言い直す
                    if let live, let last = snap.lastSpeechAt, snap.elapsed - last >= 1.0,
                       PardonDetector.isPardon(live.text) {
                        askedToRepeat = true
                        break
                    }
                    if let last = snap.lastSpeechAt, snap.elapsed - last >= endAfterSilence { break }
                    if canReprompt, snap.firstSpeechAt == nil, snap.elapsed >= 6 {
                        shouldReprompt = true
                        break
                    }
                }
            } catch {
                _ = recorder.stop()
                live?.stop()
                isListening = false
                throw error
            }

            let recording = recorder.stop()
            live?.stop()
            isListening = false
            listenRemaining = nil
            level = 0

            var checkedTranscript: Transcript?
            if checkFileForPardon, let recording {
                isCheckingAnswer = true
                let transcript = (try? await Transcriber.transcribe(url: recording.url)) ?? .empty
                isCheckingAnswer = false
                NSLog("[Pardon] 録音ファイル: '%@'", transcript.text)
                if PardonDetector.isPardon(transcript.text) {
                    askedToRepeat = true
                } else {
                    checkedTranscript = transcript
                }
            }

            if askedToRepeat, let repeatable {
                pardons += 1
                repeatsForThisQuestion += 1
                isRepeatingQuestion = true
                defer { isRepeatingQuestion = false }
                if repeatsForThisQuestion <= 2 {
                    try await say("Sure. \(repeatable)")
                } else {
                    try await say("Please try to answer the question.")
                }
                continue
            }
            if shouldReprompt, let reprompt {
                canReprompt = false
                reprompts += 1
                try await say(reprompt)
                continue
            }
            if let recording {
                recordings[key] = recording
                if let checkedTranscript {
                    // 聞き返しの確認で文字起こし済みなので、それを採点に使う
                    transcriptTasks[key] = Task { checkedTranscript }
                } else {
                    enqueueTranscription(key, recording.url)
                }
            }
            return
        }
    }

    /// 文字起こしは面接の進行と並行して、1件ずつ順番に行う
    private func enqueueTranscription(_ key: AnswerKey, _ url: URL) {
        let previous = lastTranscriptTask
        let task = Task<Transcript, Never> {
            _ = await previous?.value
            do {
                return try await Transcriber.transcribe(url: url)
            } catch {
                print("[Transcriber] \(key.rawValue): \(error)")
                return .empty
            }
        }
        transcriptTasks[key] = task
        lastTranscriptTask = task
    }
}

enum SessionError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "マイクの使用が許可されていません。設定アプリで「英検2級面接」のマイクをオンにしてください。"
        }
    }
}
