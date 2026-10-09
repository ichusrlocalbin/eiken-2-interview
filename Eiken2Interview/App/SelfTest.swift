#if DEBUG
import Foundation

/// 開発用: 起動引数 `-selftest` で、Documents/selftest/*.m4a を文字起こし・採点してログに出す
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-selftest") }

    /// シミュレータでは音声認識が使えないため、文字起こしの代わりに使う回答例（set-001 用）
    static let sampleAnswers: [AnswerKey: String] = [
        .greeting: "I'm fine, thank you.",
        .reading: "Today, many restaurants offer food delivery services. Customers can order meals by using their smartphones and enjoy them at home. However, some customers complain that the food is cold when it arrives. Some restaurants now use special boxes that keep food warm, and by doing so, they can satisfy their customers. Such services will become more popular.",
        .no1: "They use special box that keep food warm. They charge for the prostitution.",
        .no2: "One day, Mr. and Mrs. Kato were talking about their son's birthday party. Mrs. Kato said, let's order a cake online. The next day, Mr. Kato order a cake on the computer. On the day of the party, a man bring a cake.",
        .no3: "I disagree. Because cooking at home is cheap.",
        .no4: "Yes, I think so.",
        .no4Why: "It is very easy and fast. And we don't need money in our wallet.",
    ]

    @MainActor
    static func run() async {
        guard let problem = ProblemStore.loadAll().first else { return }
        let dir = URL.documentsDirectory.appending(path: "selftest")
        var recordings: [AnswerKey: Recording] = [:]
        var transcripts: [AnswerKey: Transcript] = [:]
        do {
            try await Transcriber.prepare()
            for key in AnswerKey.allCases {
                let url = dir.appending(path: "\(key.rawValue).m4a")
                recordings[key] = Recording(url: url, relativePath: "selftest/\(key.rawValue).m4a", duration: 30, firstSpeechAt: 1)
                if FileManager.default.fileExists(atPath: url.path), let t = try? await Transcriber.transcribe(url: url), !t.text.isEmpty {
                    transcripts[key] = t
                } else {
                    transcripts[key] = sampleAnswers[key].map { Transcript(text: $0, words: []) }
                }
                NSLog("[SelfTest] \(key.rawValue): \(transcripts[key]?.text ?? "")")
            }
        } catch {
            NSLog("[SelfTest] error: \(error)")
        }
        let items = await InterviewScorer(problem: problem, recordings: recordings, transcripts: transcripts, reprompts: 0)
            .score { NSLog("[SelfTest] \($0)") }
        for item in items {
            NSLog("[SelfTest] RESULT \(item.kind.rawValue) \(item.score)/\(item.kind.maxScore) est=\(item.isEstimated) good=\(item.goodPoints) improve=\(item.improvements) tags=\(item.tags)")
        }
        NSLog("[SelfTest] DONE summary=\(InterviewScorer.summaryAdvice(items))")
    }
}
#endif

#if DEBUG
import SwiftData
import SwiftUI

/// 開発用: `-seedHistory` でダミーの履歴を入れ、`-screen history|review|problems` で各画面を直接開く
enum DebugScreens {
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-screen"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    @MainActor
    static func seedIfRequested(_ context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("-seedHistory"),
              (try? context.fetchCount(FetchDescriptor<PracticeSession>())) == 0
        else { return }
        let problems = ProblemStore.loadAll()
        let scores: [[Int]] = [[3, 2, 4, 2, 2, 2], [4, 3, 5, 3, 2, 3], [4, 3, 6, 2, 3, 3], [5, 4, 6, 3, 3, 3], [4, 5, 7, 4, 3, 3], [5, 4, 8, 4, 4, 3]]
        let tags = [["oneReasonOnly"], ["tense", "thirdPersonS"], ["oneReasonOnly", "tense"], ["copiedPassage"], ["tense"], []]
        for (index, row) in scores.enumerated() {
            let items = zip(ItemKind.allCases, row).map { kind, score in
                ItemOutcome(kind: kind, score: score, transcript: "", audioFiles: [], goodPoints: [], improvements: [],
                            modelAnswer: nil, tags: kind == .no3 ? tags[index] : [])
            }
            let outcome = InterviewOutcome(
                sessionID: UUID(), date: Date.now.addingTimeInterval(Double(index - 6) * 86_400),
                problemSetId: problems[index % problems.count].id, problemTitle: problems[index % problems.count].title,
                items: items, summaryAdvice: "【No.3】理由を2つ言おう。"
            )
            context.insert(PracticeSession(outcome: outcome))
        }
    }
}
#endif
