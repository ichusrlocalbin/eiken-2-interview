import PhotosUI
import SwiftUI

/// 問題の手入力・編集。イラストは写真から選ぶ（問題集のカードを撮影したものなど）
struct ProblemEditorView: View {
    let original: ProblemSet?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var passage = ""
    @State private var no1Question = ""
    @State private var no1Answer = ""
    @State private var no1KeyPoints = ""
    @State private var opening = ""
    @State private var panelDescriptions = ["", "", ""]
    @State private var timeLabels = ["", ""]
    @State private var no2Answer = ""
    @State private var no3Question = ""
    @State private var no3Answer = ""
    @State private var no4Question = ""
    @State private var no4Yes = ""
    @State private var no4No = ""

    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var errorMessage: String?

    init(original: ProblemSet? = nil, onSave: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
    }

    private var canSave: Bool {
        [title, passage, no1Question, opening, no3Question, no4Question]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("タイトル（例: Food Delivery Services）", text: $title)
                    TextEditor(text: $passage)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) { placeholder("パッセージ（約60語の英文）", show: passage.isEmpty) }
                } header: {
                    Text("問題カード")
                }

                Section {
                    TextField("質問（According to the passage, ...?）", text: $no1Question, axis: .vertical)
                    TextField("模範解答", text: $no1Answer, axis: .vertical)
                    TextField("採点の要点（1行に1つ・省略可）", text: $no1KeyPoints, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("No.1")
                }

                Section {
                    TextField("最初の文（One day, ...）", text: $opening, axis: .vertical)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(previewImage == nil ? "イラストを写真から選ぶ" : "イラストを選び直す", systemImage: "photo")
                    }
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160)
                    }
                    ForEach(0..<3, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(index + 1)コマ目").font(.caption).foregroundStyle(.secondary)
                            if index > 0 {
                                TextField("時間の表現（例: Later that day）", text: $timeLabels[index - 1])
                            }
                            TextField("何が描かれているか（日本語でOK）", text: $panelDescriptions[index], axis: .vertical)
                        }
                    }
                    TextField("模範解答（省略可）", text: $no2Answer, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("No.2 イラスト")
                } footer: {
                    Text("各コマの説明は、AIが採点するときの手がかりになります。")
                }

                Section("No.3") {
                    TextField("質問（Some people say that ... What do you think about that?）", text: $no3Question, axis: .vertical)
                    TextField("模範解答（省略可）", text: $no3Answer, axis: .vertical)
                }

                Section("No.4") {
                    TextField("質問（Today, ... Do you think ...?）", text: $no4Question, axis: .vertical)
                    TextField("模範解答 Yes の場合（省略可）", text: $no4Yes, axis: .vertical)
                    TextField("模範解答 No の場合（省略可）", text: $no4No, axis: .vertical)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(original == nil ? "問題を追加" : "問題を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            .onChange(of: photoItem) { _, item in
                Task { await loadPhoto(item) }
            }
        }
    }

    private func placeholder(_ text: String, show: Bool) -> some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
            .padding(.leading, 5)
            .opacity(show ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func load() {
        guard let p = original, title.isEmpty else { return }
        title = p.title
        passage = p.passage
        no1Question = p.no1.question
        no1Answer = p.no1.modelAnswer
        no1KeyPoints = p.no1.keyPoints.joined(separator: "\n")
        opening = p.no2.openingSentence
        for index in 0..<3 where p.no2.panels.indices.contains(index) {
            panelDescriptions[index] = p.no2.panels[index].keyPoints.joined(separator: " / ")
            if index > 0 { timeLabels[index - 1] = p.no2.panels[index].timeLabel ?? "" }
        }
        no2Answer = p.no2.modelAnswer
        no3Question = p.no3.question
        no3Answer = p.no3.modelAnswer
        no4Question = p.no4.question
        no4Yes = p.no4.modelAnswerYes
        no4No = p.no4.modelAnswerNo
        previewImage = ProblemStore.illustration(named: p.no2.image)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return }
        // HEIC などもあるので JPEG に変換してから保存する
        imageData = image.jpegData(compressionQuality: 0.85)
        previewImage = image
    }

    private func save() {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let panels = (0..<3).map { index in
            ProblemSet.Panel(
                timeLabel: index == 0 ? nil : (clean(timeLabels[index - 1]).isEmpty ? nil : clean(timeLabels[index - 1])),
                keyPoints: clean(panelDescriptions[index]).isEmpty ? [] : [clean(panelDescriptions[index])]
            )
        }
        let problem = ProblemSet(
            id: original?.id ?? ProblemStore.newCustomID(),
            title: clean(title),
            passage: clean(passage),
            no1: .init(
                question: clean(no1Question),
                modelAnswer: clean(no1Answer),
                keyPoints: no1KeyPoints.split(separator: "\n").map { clean(String($0)) }.filter { !$0.isEmpty }
            ),
            no2: .init(image: original?.no2.image ?? "", openingSentence: clean(opening), panels: panels, modelAnswer: clean(no2Answer)),
            no3: .init(question: clean(no3Question), modelAnswer: clean(no3Answer)),
            no4: .init(question: clean(no4Question), modelAnswerYes: clean(no4Yes), modelAnswerNo: clean(no4No))
        )
        do {
            try ProblemStore.save(problem, imageData: imageData)
            onSave()
            dismiss()
        } catch {
            errorMessage = "保存できませんでした: \(error.localizedDescription)"
        }
    }
}
