import SwiftData
import SwiftUI

@main
struct Eiken2InterviewApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            DebugRoot()
                .task { if SelfTest.isRequested { await SelfTest.run() } }
            #else
            HomeView()
            #endif
        }
        .modelContainer(for: PracticeSession.self)
    }
}

#if DEBUG
private struct DebugRoot: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            switch DebugScreens.screen {
            case "history": NavigationStack { HistoryView() }
            case "review": NavigationStack { ReviewView(problems: ProblemStore.loadAll()) { _, _ in } }
            case "problems": NavigationStack { ProblemManagerView {} }
            case "drill": NavigationStack { DrillView(problems: ProblemStore.loadAll()) { _ in } }
            default: HomeView()
            }
        }
        .onAppear { DebugScreens.seedIfRequested(context) }
    }
}
#endif
