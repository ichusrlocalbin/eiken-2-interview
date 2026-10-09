import AVFoundation
import Speech

struct TimedWord: Codable, Hashable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct Transcript: Codable, Hashable, Sendable {
    let text: String
    let words: [TimedWord]

    static let empty = Transcript(text: "", words: [])

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

enum TranscriberError: LocalizedError {
    case unsupportedLocale
    case audioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "この端末では英語（米国）の音声認識が使えません。"
        case .audioFormat: "録音した音声を音声認識用に変換できませんでした。"
        }
    }
}

/// SpeechAnalyzer（iOS 26〜）で録音ファイルを文字起こしする。
/// `SpeechTranscriber` が使えない環境（シミュレータなど）では `DictationTranscriber` を使う。
enum Transcriber {
    static let locale = Locale(identifier: "en-US")

    private static var useSpeechTranscriber: Bool { SpeechTranscriber.isAvailable }

    private static func makeSpeechModule() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    private static func makeDictationModule() -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    private static func makeModule() -> any SpeechModule {
        useSpeechTranscriber ? makeSpeechModule() : makeDictationModule()
    }

    @MainActor private static var preparation: Task<Void, Error>?

    /// 音声認識の準備（言語の予約・モデルのダウンロード）。一度成功したら結果を使い回す
    @MainActor
    static func prepare() async throws {
        if let preparation {
            return try await preparation.value
        }
        let task = Task { try await prepareOnce() }
        preparation = task
        do {
            try await task.value
        } catch {
            preparation = nil  // 失敗したときは次回やり直す
            throw error
        }
    }

    private static func prepareOnce() async throws {
        let supported = useSpeechTranscriber
            ? await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            : await DictationTranscriber.supportedLocale(equivalentTo: locale)
        guard let supported else { throw TranscriberError.unsupportedLocale }
        // アプリが使う言語を予約しておかないと、モデルの状態確認やダウンロードができない
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: supported)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) {
            try await request.downloadAndInstall()
        }
    }

    static func transcribe(url: URL) async throws -> Transcript {
        try await prepare()
        if useSpeechTranscriber {
            let module = makeSpeechModule()
            return try await run(module, url: url, results: module.results) { ($0.text, $0.isFinal) }
        } else {
            let module = makeDictationModule()
            return try await run(module, url: url, results: module.results) { ($0.text, $0.isFinal) }
        }
    }

    private static func run<Results: AsyncSequence & Sendable>(
        _ module: some SpeechModule,
        url: URL,
        results: Results,
        extract: @escaping @Sendable (Results.Element) -> (AttributedString, Bool)
    ) async throws -> Transcript {
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)

        let collector = Task { () throws -> Transcript in
            var segments: [String] = []
            var words: [TimedWord] = []
            for try await element in results {
                let (text, isFinal) = extract(element)
                guard isFinal else { continue }
                segments.append(String(text.characters))
                for run in text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty else { continue }
                    words.append(TimedWord(text: word, start: range.start.seconds, end: range.end.seconds))
                }
            }
            let text = segments
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return Transcript(text: text, words: words)
        }

        // 録音ファイルの形式のままだと受け付けないことがあるため、認識エンジンの形式に変換して流し込む
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            NSLog("[Transcriber] bestAvailableAudioFormat が nil")
            throw TranscriberError.audioFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        do {
            for buffer in try convert(file, to: format) {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private static func convert(_ file: AVAudioFile, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        let source = file.processingFormat
        let chunk: AVAudioFrameCount = 8192
        guard let converter = AVAudioConverter(from: source, to: format) else {
            NSLog("[Transcriber] 変換できない形式: \(source) -> \(format)")
            throw TranscriberError.audioFormat
        }
        var output: [AVAudioPCMBuffer] = []
        var finished = false
        while !finished {
            let capacity = AVAudioFrameCount(Double(chunk) * format.sampleRate / source.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
                      (try? file.read(into: input, frameCount: chunk)) != nil,
                      input.frameLength > 0
                else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if out.frameLength > 0 { output.append(out) }
            finished = status == .endOfStream || status == .error || out.frameLength == 0
        }
        return output
    }
}

/// 回答の録音中に並行して動かすリアルタイムの文字起こし（聞き返しの検出用）。
/// 精度より速さを優先し、採点には録音ファイルの文字起こしを使う
final class LiveTranscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var task: Task<Void, Never>?

    /// 実機のみ（SpeechTranscriber が使えない環境では nil）
    static func makeIfAvailable() -> LiveTranscriber? {
        SpeechTranscriber.isAvailable ? LiveTranscriber() : nil
    }

    /// 文字起こしできた内容（確定した部分＋途中の部分）
    var text: String {
        lock.withLock { (finalized + " " + volatile).trimmingCharacters(in: .whitespaces) }
    }

    func start(inputFormat: AVAudioFormat) {
        let module = SpeechTranscriber(
            locale: Transcriber.locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: []
        )
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        task = Task { [weak self] in
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                NSLog("[Live] 音声形式を取得できません")
                return
            }
            NSLog("[Live] 開始 %@ → %@", inputFormat.description, format.description)
            self?.lock.withLock {
                self?.outputFormat = format
                self?.converter = AVAudioConverter(from: inputFormat, to: format)
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            do {
                try await analyzer.start(inputSequence: stream)
                for try await result in module.results {
                    let text = String(result.text.characters)
                    NSLog("[Live] %@: %@", result.isFinal ? "確定" : "途中", text)
                    self?.lock.withLock {
                        if result.isFinal {
                            self?.finalized += " " + text
                            self?.volatile = ""
                        } else {
                            self?.volatile = text
                        }
                    }
                }
            } catch {
                print("[LiveTranscriber] \(error)")
            }
            await analyzer.cancelAndFinishNow()
        }
    }

    /// 録音のタップ（音声スレッド）から呼ばれる
    func feed(_ buffer: AVAudioPCMBuffer) {
        let (converter, format) = lock.withLock { (self.converter, self.outputFormat) }
        guard let converter, let format, let continuation else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
    }
}

/// 「もう一度言ってください」の言い方かどうか
enum PardonDetector {
    static let phrases = [
        "pardon", "excuse me", "again", "repeat", "one more time", "once more",
        "sorry", "didn't catch", "did not catch", "didn't hear", "did not hear",
    ]
    static let maxWords = 10

    /// 短い発話（10語以内）で、聞き返しの言い方を含むとき true
    static func isPardon(_ text: String) -> Bool {
        let words = ScoringRules.words(text).filter { !ScoringRules.fillers.contains($0) }
        guard !words.isEmpty, words.count <= maxWords else { return false }
        let joined = words.joined(separator: " ")
        return phrases.contains { joined.contains($0) }
    }
}
