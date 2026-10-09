import SwiftUI

/// 問題カード（パッセージ＋3コマイラスト）
struct ProblemCardView: View {
    let problem: ProblemSet
    var dimPassage = false
    /// No.1 の手がかり（"by doing so" などを含む文）を黄色で示す
    var highlightsCue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(problem.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                Text(highlightsCue ? Self.highlighted(problem.passage) : AttributedString(problem.passage))
                    .font(.system(.body, design: .serif))
                    .lineSpacing(6)
            }
            .opacity(dimPassage ? 0.35 : 1)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Your story should begin with this sentence:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(problem.no2.openingSentence)
                    .font(.system(.callout, design: .serif))
                    .italic()
                IllustrationView(no2: problem.no2)
            }
            .id("illustration")
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

extension ProblemCardView {
    static let cues = ["by doing so", "in this way", "by doing this", "as a result"]

    /// 手がかりの表現を含む文に黄色の背景をつける
    static func highlighted(_ passage: String) -> AttributedString {
        var result = AttributedString()
        let sentences = passage.split(separator: ". ", omittingEmptySubsequences: false)
        for (index, sentence) in sentences.enumerated() {
            let text = String(sentence) + (index < sentences.count - 1 ? ". " : "")
            var piece = AttributedString(text)
            if cues.contains(where: { text.lowercased().contains($0) }) {
                piece.backgroundColor = .yellow.opacity(0.45)
            }
            result += piece
        }
        return result
    }
}

struct IllustrationView: View {
    let no2: ProblemSet.No2

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(no2.panels.indices, id: \.self) { index in
                    Text(no2.panels[index].timeLabel ?? " ")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
            }
            if let image = ProblemStore.illustration(named: no2.image) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                placeholder
            }
        }
    }

    /// イラストがまだ無い問題は、各コマの要点を文字で表示する
    private var placeholder: some View {
        HStack(spacing: 6) {
            ForEach(no2.panels.indices, id: \.self) { index in
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                    Text(no2.panels[index].keyPoints.joined(separator: "\n"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            }
        }
    }
}

/// No.3 以降の「カードを伏せた」状態
struct CardTurnedOverView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.largeTitle)
            Text("カードは伏せてあります")
                .font(.headline)
            Text("面接官の質問をよく聞いて、自分の考えを答えよう")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}
