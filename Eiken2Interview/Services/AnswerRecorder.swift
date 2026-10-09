import AVFoundation

struct Recording: Sendable {
    let url: URL
    let relativePath: String
    let duration: TimeInterval
    /// 録音開始から話し始めるまでの秒数。話さなかった場合 nil
    let firstSpeechAt: TimeInterval?
}

/// マイク入力を m4a に保存しながら、音量から「話しているか」を判定する。
/// タップのコールバックは音声スレッドで呼ばれるため、状態はロックで守る。
final class AnswerRecorder: @unchecked Sendable {
    struct Snapshot {
        let elapsed: TimeInterval
        let level: Float
        let firstSpeechAt: TimeInterval?
        let lastSpeechAt: TimeInterval?
    }

    /// 周りの静かさを測るまでの基準（dB）
    static let defaultThresholdDB: Float = -45

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var relativePath = ""
    private var sampleRate: Double = 48_000
    private var frames: AVAudioFramePosition = 0
    private var levelDB: Float = -160
    private var firstSpeechFrame: AVAudioFramePosition?
    /// 録音開始直後（0.5秒）の一番静かな音量。これより 10dB 大きい音を「話している」とみなす
    private var noiseFloorDB: Float = 0
    private var thresholdDB: Float = AnswerRecorder.defaultThresholdDB
    private var lastSpeechFrame: AVAudioFramePosition?
    private(set) var isRunning = false

    /// マイク入力の形式（リアルタイム文字起こしの準備に使う）
    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// `onBuffer` には録音中の音声がそのまま渡される（音声スレッドから呼ばれる）
    func start(url: URL, relativePath: String, onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        lock.withLock {
            self.file = file
            self.relativePath = relativePath
            sampleRate = format.sampleRate
            frames = 0
            levelDB = -160
            noiseFloorDB = 0
            thresholdDB = Self.defaultThresholdDB
            firstSpeechFrame = nil
            lastSpeechFrame = nil
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
            onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func pause() {
        guard isRunning else { return }
        engine.pause()
    }

    func resume() {
        guard isRunning else { return }
        try? engine.start()
    }

    func stop() -> Recording? {
        guard isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        return lock.withLock {
            let url = file?.url
            file = nil  // 参照を外すとファイルが閉じられる
            guard let url else { return nil }
            return Recording(
                url: url,
                relativePath: relativePath,
                duration: Double(frames) / sampleRate,
                firstSpeechAt: firstSpeechFrame.map { Double($0) / sampleRate }
            )
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                elapsed: Double(frames) / sampleRate,
                level: levelDB,
                firstSpeechAt: firstSpeechFrame.map { Double($0) / sampleRate },
                lastSpeechAt: lastSpeechFrame.map { Double($0) / sampleRate }
            )
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let db = Self.rmsDB(buffer)
        lock.withLock {
            try? file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            levelDB = db
            if Double(frames) / sampleRate <= 0.5 {
                noiseFloorDB = min(noiseFloorDB, db)
                // 静かな部屋では基準を下げて小さな声も拾い、うるさい場所では上げる（-55〜-38dB の範囲）
                thresholdDB = max(-55, min(-38, noiseFloorDB + 10))
            }
            if db > thresholdDB {
                if firstSpeechFrame == nil { firstSpeechFrame = frames }
                lastSpeechFrame = frames
            }
        }
    }

    private static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}
