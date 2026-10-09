import SwiftUI
import UniformTypeIdentifiers

/// 問題の一覧・追加・取り込み・削除
struct ProblemManagerView: View {
    let onChange: () -> Void
    @State private var bundled = ProblemStore.bundled()
    @State private var custom = ProblemStore.custom()
    @State private var editing: ProblemSet?
    @State private var showEditor = false
    @State private var showImporter = false
    @State private var showFormat = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                if custom.isEmpty {
                    Text("まだありません。右上の ＋ から追加できます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(custom) { problem in
                    Button {
                        editing = problem
                    } label: {
                        HStack {
                            Text(problem.title).foregroundStyle(.primary)
                            Spacer()
                            if problem.no2.image.isEmpty {
                                Label("イラストなし", systemImage: "photo.badge.exclamationmark")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { custom[$0] }.forEach(ProblemStore.delete)
                    reload()
                }
            } header: {
                Text("自分で追加した問題（\(custom.count)）")
            } footer: {
                Text("タップで編集、左にスワイプで削除できます。")
            }

            Section("付属の問題（\(bundled.count)）") {
                ForEach(bundled) { problem in
                    Text(problem.title)
                }
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("問題の管理")
        .toolbar {
            Menu {
                Button {
                    showEditor = true
                } label: {
                    Label("手入力で追加", systemImage: "square.and.pencil")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("JSONファイルを取り込む", systemImage: "doc.badge.plus")
                }
                Button {
                    showFormat = true
                } label: {
                    Label("JSONの書き方", systemImage: "questionmark.circle")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showEditor) {
            ProblemEditorView(onSave: reload)
        }
        .sheet(item: $editing) { problem in
            ProblemEditorView(original: problem, onSave: reload)
        }
        .sheet(isPresented: $showFormat) {
            JSONFormatView()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var count = 0
                var failed: [String] = []
                for url in urls {
                    do { count += try ProblemStore.importJSON(from: url) } catch { failed.append(url.lastPathComponent) }
                }
                message = "\(count) 問を取り込みました。" + (failed.isEmpty ? "" : "\n読み込めなかったファイル: \(failed.joined(separator: ", "))")
                reload()
            case .failure(let error):
                message = "取り込めませんでした: \(error.localizedDescription)"
            }
        }
    }

    private func reload() {
        custom = ProblemStore.custom()
        onChange()
    }
}

private struct JSONFormatView: View {
    @Environment(\.dismiss) private var dismiss

    static let sample = """
    {
      "title": "Food Delivery Services",
      "passage": "Today, many restaurants offer ...",
      "no1": {
        "question": "According to the passage, how can ...?",
        "modelAnswer": "By using ...",
        "keyPoints": ["要点1", "要点2"]
      },
      "no2": {
        "openingSentence": "One day, ...",
        "panels": [
          {"timeLabel": null, "keyPoints": ["1コマ目の説明"]},
          {"timeLabel": "The next day", "keyPoints": ["2コマ目の説明"]},
          {"timeLabel": "That evening", "keyPoints": ["3コマ目の説明"]}
        ],
        "modelAnswer": "One day, ..."
      },
      "no3": {"question": "Some people say that ... What do you think about that?", "modelAnswer": "..."},
      "no4": {"question": "Today, ... Do you think ...?", "modelAnswerYes": "...", "modelAnswerNo": "..."}
    }
    """

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1問なら下の形、複数なら [ ] で囲んだ配列にします。modelAnswer・keyPoints・timeLabel は省略できます。イラストは取り込んだあと、問題をタップして写真から追加してください。")
                        .font(.callout)
                    Text(Self.sample)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    Button {
                        UIPasteboard.general.string = Self.sample
                    } label: {
                        Label("見本をコピー", systemImage: "doc.on.doc")
                    }
                }
                .padding()
            }
            .navigationTitle("JSONの書き方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}
