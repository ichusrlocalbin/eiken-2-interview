import Foundation
import UIKit

/// 問題カード1枚分（パッセージ・イラスト・No.1〜4）。`Problems/set-*.json` から読み込む。
/// 自分で追加する問題のために、要点・模範解答などは省略できる（省略時は空）。
struct ProblemSet: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var passage: String
    var no1: No1
    var no2: No2
    var no3: No3
    var no4: No4

    struct No1: Codable, Hashable {
        var question: String
        var modelAnswer: String
        var keyPoints: [String]

        init(question: String, modelAnswer: String, keyPoints: [String]) {
            self.question = question
            self.modelAnswer = modelAnswer
            self.keyPoints = keyPoints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = try c.decode(String.self, forKey: .question)
            modelAnswer = try c.decodeIfPresent(String.self, forKey: .modelAnswer) ?? ""
            keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        }
    }

    struct No2: Codable, Hashable {
        var image: String
        var openingSentence: String
        var panels: [Panel]
        var modelAnswer: String

        init(image: String, openingSentence: String, panels: [Panel], modelAnswer: String) {
            self.image = image
            self.openingSentence = openingSentence
            self.panels = panels
            self.modelAnswer = modelAnswer
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
            openingSentence = try c.decode(String.self, forKey: .openingSentence)
            panels = try c.decodeIfPresent([Panel].self, forKey: .panels) ?? []
            modelAnswer = try c.decodeIfPresent(String.self, forKey: .modelAnswer) ?? ""
        }
    }

    struct Panel: Codable, Hashable {
        /// 2・3コマ目の上に表示する時間の表現（例: "Later that day"）。1コマ目は nil
        var timeLabel: String?
        var keyPoints: [String]

        init(timeLabel: String?, keyPoints: [String]) {
            self.timeLabel = timeLabel
            self.keyPoints = keyPoints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timeLabel = try c.decodeIfPresent(String.self, forKey: .timeLabel)
            keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        }
    }

    struct No3: Codable, Hashable {
        var question: String
        var modelAnswer: String
        var rubricHints: [String]

        init(question: String, modelAnswer: String, rubricHints: [String] = ProblemSet.opinionHints) {
            self.question = question
            self.modelAnswer = modelAnswer
            self.rubricHints = rubricHints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = try c.decode(String.self, forKey: .question)
            modelAnswer = try c.decodeIfPresent(String.self, forKey: .modelAnswer) ?? ""
            rubricHints = try c.decodeIfPresent([String].self, forKey: .rubricHints) ?? ProblemSet.opinionHints
        }
    }

    struct No4: Codable, Hashable {
        var question: String
        var modelAnswerYes: String
        var modelAnswerNo: String
        var rubricHints: [String]

        init(question: String, modelAnswerYes: String, modelAnswerNo: String, rubricHints: [String] = ProblemSet.yesNoHints) {
            self.question = question
            self.modelAnswerYes = modelAnswerYes
            self.modelAnswerNo = modelAnswerNo
            self.rubricHints = rubricHints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = try c.decode(String.self, forKey: .question)
            modelAnswerYes = try c.decodeIfPresent(String.self, forKey: .modelAnswerYes) ?? ""
            modelAnswerNo = try c.decodeIfPresent(String.self, forKey: .modelAnswerNo) ?? ""
            rubricHints = try c.decodeIfPresent([String].self, forKey: .rubricHints) ?? ProblemSet.yesNoHints
        }
    }

    static let opinionHints = ["agree / disagree を最初にはっきり言う", "理由を2つ、または理由＋具体例"]
    static let yesNoHints = ["Yes / No を最初に言う", "理由を2つ"]

    var isCustom: Bool { id.hasPrefix(ProblemStore.customPrefix) }

    init(id: String, title: String, passage: String, no1: No1, no2: No2, no3: No3, no4: No4) {
        self.id = id
        self.title = title
        self.passage = passage
        self.no1 = no1
        self.no2 = no2
        self.no3 = no3
        self.no4 = no4
    }

    /// 取り込む JSON では id を省略できる（取り込み時に振り直す）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decode(String.self, forKey: .title)
        passage = try c.decode(String.self, forKey: .passage)
        no1 = try c.decode(No1.self, forKey: .no1)
        no2 = try c.decode(No2.self, forKey: .no2)
        no3 = try c.decode(No3.self, forKey: .no3)
        no4 = try c.decode(No4.self, forKey: .no4)
    }
}

enum ProblemStore {
    static let customPrefix = "custom-"

    /// 自分で追加した問題（JSON とイラスト）の保存先
    static var customDirectory: URL {
        URL.documentsDirectory.appending(path: "CustomProblems", directoryHint: .isDirectory)
    }

    static func loadAll() -> [ProblemSet] {
        bundled() + custom()
    }

    static func bundled() -> [ProblemSet] {
        let bundle = Bundle.main
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Problems") ?? [])
        return decode(urls.filter { $0.lastPathComponent.hasPrefix("set-") })
    }

    static func custom() -> [ProblemSet] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil)) ?? []
        return decode(urls.filter { $0.pathExtension == "json" })
    }

    private static func decode(_ urls: [URL]) -> [ProblemSet] {
        let decoder = JSONDecoder()
        var seen = Set<String>()
        return urls
            .compactMap { url -> ProblemSet? in
                do {
                    return try decoder.decode(ProblemSet.self, from: Data(contentsOf: url))
                } catch {
                    print("[ProblemStore] \(url.lastPathComponent) の読み込みに失敗: \(error)")
                    return nil
                }
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    static func newCustomID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return customPrefix + formatter.string(from: .now) + "-" + UUID().uuidString.prefix(4).lowercased()
    }

    /// 自分で追加した問題を保存する。`imageData` があればイラストも保存する
    static func save(_ problem: ProblemSet, imageData: Data? = nil) throws {
        var problem = problem
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        if let imageData {
            let name = "\(problem.id)-illust.jpg"
            try imageData.write(to: customDirectory.appending(path: name))
            problem.no2.image = name
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(problem).write(to: customDirectory.appending(path: "\(problem.id).json"))
    }

    static func delete(_ problem: ProblemSet) {
        guard problem.isCustom else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: customDirectory.appending(path: "\(problem.id).json"))
        if !problem.no2.image.isEmpty {
            try? fm.removeItem(at: customDirectory.appending(path: problem.no2.image))
        }
    }

    /// JSON ファイル（1問の object または問題の配列）を取り込む。ID は自分用の問題として振り直す
    static func importJSON(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let problems: [ProblemSet]
        if let list = try? decoder.decode([ProblemSet].self, from: data) {
            problems = list
        } else {
            problems = [try decoder.decode(ProblemSet.self, from: data)]
        }
        for var problem in problems {
            problem.id = newCustomID()
            // 取り込み時は画像がないので、あとで編集画面から写真を追加する
            problem.no2.image = ""
            try save(problem)
        }
        return problems.count
    }

    static func illustration(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let customURL = customDirectory.appending(path: name)
        if FileManager.default.fileExists(atPath: customURL.path) {
            return UIImage(contentsOfFile: customURL.path)
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        let url = Bundle.main.url(forResource: base, withExtension: ext)
            ?? Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Problems")
        return url.flatMap { UIImage(contentsOfFile: $0.path) }
    }
}
