import AVFoundation

/// 面接官の読み上げ。`speak` は読み上げが終わるまで待つ。
@MainActor
final class InterviewerVoice: NSObject, AVSpeechSynthesizerDelegate {
    fileprivate let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, rate: Float = AppSettings.speechRate) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.3
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-mute") { utterance.volume = 0 }
        #endif
        currentUtterance = ObjectIdentifier(utterance)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func pause() {
        if synthesizer.isSpeaking { synthesizer.pauseSpeaking(at: .immediate) }
    }

    func resume() {
        if synthesizer.isPaused { synthesizer.continueSpeaking() }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish(nil)
    }

    private func finish(_ id: ObjectIdentifier?) {
        if let id, id != currentUtterance { return }
        currentUtterance = nil
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        StartupTimer.mark("読み上げ開始: \(utterance.speechString.prefix(20))")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    /// 面接で使う読み上げ。ホーム画面で温めておいたものをそのまま使う
    static let shared = InterviewerVoice()
    private static var isWarmedUp = false

    /// ホーム画面にいる間に、録音・再生用の音声設定と声の読み込みを済ませておき、面接開始直後の読み上げを速くする
    static func warmUp() {
        guard !isWarmedUp else { return }
        isWarmedUp = true
        AudioSessionConfig.activateForInterview()
        let utterance = AVSpeechUtterance(string: "Hello")
        utterance.voice = voice
        utterance.volume = 0
        shared.synthesizer.speak(utterance)
    }

    /// 端末にある en-US の声のうち、品質が一番高いもの
    static let voice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()
}

enum AppSettings {
    static let speechRateKey = "speechRate"

    static var speechRate: Float {
        let value = UserDefaults.standard.object(forKey: speechRateKey) as? Double
        return Float(value ?? 0.45)
    }
}

/// 開始ボタンから面接官が話し始めるまでの時間を測る（ログに出す）
enum StartupTimer {
    nonisolated(unsafe) private static var start: Date?

    static func begin() {
        start = .now
        NSLog("[Startup] 0.000s 開始ボタン")
    }

    static func mark(_ label: String) {
        guard let start else { return }
        NSLog("[Startup] %.3fs %@", Date.now.timeIntervalSince(start), label)
    }
}

enum AudioSessionConfig {
    /// 面接用（再生と録音）の音声設定。すでに同じ設定なら何もしない
    @discardableResult
    static func activateForInterview() -> Error? {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playAndRecord {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            }
            try session.setActive(true)
            return nil
        } catch {
            return error
        }
    }
}
