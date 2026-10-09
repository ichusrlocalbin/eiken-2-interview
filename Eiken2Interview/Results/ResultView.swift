import AVFoundation
import SwiftUI

struct ResultView: View {
    let outcome: InterviewOutcome

    var body: some View {
        List {
            Section {
                ScoreHeader(outcome: outcome)
            }
            Section("次回に意識すること") {
                Label(outcome.summaryAdvice, systemImage: "lightbulb")
            }
            Section("項目別") {
                ForEach(outcome.items) { item in
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        ItemRow(item: item)
                    }
                }
            }
        }
    }
}

private struct ScoreHeader: View {
    let outcome: InterviewOutcome

    var body: some View {
        let total = outcome.totalScore
        VStack(spacing: 8) {
            Text(outcome.mode == .full ? outcome.problemTitle : "\(outcome.problemTitle)（復習）")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(total)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text("/ \(outcome.maxScore)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if outcome.mode == .full {
                Text(message(total))
                    .font(.headline)
                    .foregroundStyle(total >= InterviewOutcome.passLine ? .green : .orange)
                Text("合格の目安は \(InterviewOutcome.passLine) 点前後")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let ratio = Double(total) / Double(max(1, outcome.maxScore))
                Text(ratio >= 0.6 ? "苦手を克服できました！" : "もう一度チャレンジしよう")
                    .font(.headline)
                    .foregroundStyle(ratio >= 0.6 ? .green : .orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func message(_ total: Int) -> String {
        switch total {
        case 23...: "合格圏です！"
        case InterviewOutcome.passLine...: "合格ラインに届いています"
        default: "合格ラインまで あと \(InterviewOutcome.passLine - total) 点"
        }
    }
}

private struct ItemRow: View {
    let item: ItemOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.kind.title)
                Spacer()
                Text("\(item.score) / \(item.kind.maxScore)")
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            ProgressView(value: item.ratio)
                .tint(item.ratio >= 0.8 ? .green : item.ratio >= 0.6 ? .blue : .orange)
        }
    }
}

struct ItemDetailView: View {
    let item: ItemOutcome
    @State private var player = AudioPlayer()
    @State private var speech = SpeechPlayback()

    var body: some View {
        List {
            Section {
                HStack {
                    Text("得点")
                    Spacer()
                    Text("\(item.score) / \(item.kind.maxScore)")
                        .font(.title2.bold())
                }
                if item.isEstimated {
                    Label("AIで採点できなかったため、目安の点数です", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let question = item.question {
                Section("面接官の質問") {
                    Text(question)
                        .font(.system(.body, design: .serif))
                    speakButton(id: "question", text: question, title: "質問を聞く")
                }
            }

            if !item.goodPoints.isEmpty {
                Section("良かった点") {
                    ForEach(item.goodPoints, id: \.self) { Label($0, systemImage: "hand.thumbsup").foregroundStyle(.primary) }
                }
            }
            if !item.improvements.isEmpty {
                Section("改善点") {
                    ForEach(item.improvements, id: \.self) { Label($0, systemImage: "arrow.up.forward.circle") }
                }
            }

            if let reading = item.reading {
                Section {
                    ReadingHighlightText(analysis: reading)
                    LabeledContent("正しく読めた単語", value: "\(Int(reading.accuracy * 100))%")
                    LabeledContent("読む速さ", value: "\(Int(reading.wordsPerMinute)) 語/分")
                    LabeledContent("長い止まり（2秒以上）", value: "\(reading.longPauses) 回")
                } header: {
                    Text("音読のチェック")
                } footer: {
                    Text("赤: 読み飛ばし / オレンジ: 聞き取れなかった単語。音声認識のミスで色がつくこともあります。読む速さの目安は 100〜150 語/分。")
                }
            } else if item.kind != .attitude {
                Section("あなたの回答（文字起こし）") {
                    Text(item.transcript.isEmpty ? "（聞き取れませんでした）" : item.transcript)
                        .foregroundStyle(item.transcript.isEmpty ? .secondary : .primary)
                }
            }

            if let corrected = item.correctedAnswer {
                Section {
                    Text(corrected)
                        .font(.system(.body, design: .serif))
                    speakButton(id: "corrected", text: corrected, title: "直した英文を聞く")
                } header: {
                    Text("あなたの回答を直すと")
                } footer: {
                    Text("あなたの言いたかった内容のまま、文法だけを直した英文です。声に出して読んでみよう。")
                }
            }

            if !item.audioFiles.isEmpty {
                Section("録音") {
                    ForEach(item.audioFiles, id: \.self) { file in
                        let url = RecordingStorage.url(for: file)
                        Button {
                            speech.stop()
                            player.toggle(url)
                        } label: {
                            Label(player.playing == url ? "停止" : "自分の回答を聞く",
                                  systemImage: player.playing == url ? "stop.circle" : "play.circle")
                        }
                    }
                }
            }

            if let model = item.modelAnswer, !model.isEmpty {
                if item.kind == .reading {
                    Section {
                        speakButton(id: "model", text: model, title: "お手本の音読を聞く")
                    }
                } else {
                    Section("模範解答") {
                        Text(model)
                            .font(.system(.body, design: .serif))
                        speakButton(id: "model", text: model, title: "模範解答を聞く")
                    }
                }
            }
        }
        .navigationTitle(item.kind.shortTitle)
        .onDisappear {
            player.stop()
            speech.stop()
        }
    }

    /// 押すと読み上げ、読み上げ中にもう一度押すと停止する
    private func speakButton(id: String, text: String, title: String) -> some View {
        Button {
            player.stop()
            speech.toggle(id: id, text: text)
        } label: {
            Label(speech.playingID == id ? "停止" : title,
                  systemImage: speech.playingID == id ? "stop.circle" : "speaker.wave.2")
        }
    }
}

/// 読み上げの再生状態（どのボタンが再生中か）を持つ
@MainActor
@Observable
final class SpeechPlayback {
    private(set) var playingID: String?
    @ObservationIgnored private let voice = InterviewerVoice()

    func toggle(id: String, text: String) {
        if playingID == id {
            stop()
            return
        }
        playingID = id
        Task {
            await voice.speak(text)
            if playingID == id { playingID = nil }
        }
    }

    func stop() {
        voice.stop()
        playingID = nil
    }
}

private struct ReadingHighlightText: View {
    let analysis: ReadingAnalysis

    var body: some View {
        var text = AttributedString()
        for (index, word) in analysis.words.enumerated() {
            var piece = AttributedString(word.text)
            switch word.status {
            case .correct: break
            case .missed:
                piece.foregroundColor = .red
                piece.strikethroughStyle = .single
            case .misread:
                piece.foregroundColor = .orange
                piece.underlineStyle = .single
            }
            text += piece
            if index < analysis.words.count - 1 { text += AttributedString(" ") }
        }
        return Text(text)
            .font(.system(.body, design: .serif))
            .lineSpacing(4)
    }
}

@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url {
            stop()
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            playing = url
        } catch {
            print("[AudioPlayer] \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
