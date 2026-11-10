#if DEBUG
import Foundation
import ScannerKit

/// Window states for `scripts/screenshots.sh`, chosen with `-GRUZScreenshot <name>`. Debug builds only.
///
/// Each scenario shows `DemoScan` data, so screenshots never contain anyone's real files,
/// and the model refuses to scan or remove anything while a scenario is active.
enum ScreenshotScenario: String {
    case main
    case review
    case projects
    case growth
    case settings

    static var current: ScreenshotScenario? {
        UserDefaults.standard.string(forKey: "GRUZScreenshot").flatMap(ScreenshotScenario.init)
    }

    @MainActor
    func configure(_ model: AppModel) {
        guard let catalog = model.catalog else { return }
        model.showDemo(DemoScan.result(catalog: catalog, growth: self == .growth))
        switch self {
        case .main, .review, .settings:
            model.selectedCategory = .docker
            model.selection = Set(DemoScan.suggestedSelection)
            model.focusedItemID = "docker.buildcache"
        case .projects:
            model.selectedCategory = .projects
            model.selection = ["artifact.node_modules:\(DemoScan.home)/Developer/landing/node_modules"]
            model.focusedItemID = "artifact.venv"
        case .growth:
            model.selectedCategory = .ai
            model.growthOnly = true
            model.focusedItemID = "huggingface.models"
        }
    }
}
#endif

#if DEBUG
import CleanerKit

/// An executor for demo data that can only answer the review sheet's checks: every service is inert,
/// and the denylist uses the demo home folder so fictional paths are judged like real ones.
enum DemoExecutor {
    static func make() -> CleaningExecutor {
        CleaningExecutor(
            files: Inert(), commands: Inert(), apps: Inert(), log: Inert(), space: Inert(),
            denylist: Denylist(home: DemoScan.home, protectedRoots: ["~/Developer"])
        )
    }

    private struct Inert: FileOperations, CommandRunning, RunningAppsChecking, OperationLogging, FreeSpaceProviding {
        func moveToTrash(_ path: String) throws {}
        func removePermanently(_ path: String) throws {}
        func run(executable: String, arguments: [String]) async throws -> (status: Int32, output: String) { (0, "") }
        func locate(_ tool: String) -> String? { "/usr/local/bin/\(tool)" }
        func running(_ bundleIDs: [String]) -> [String] { [] }
        func record(_ line: String) {}
        func freeBytes() -> Int64? { nil }
    }
}
#endif
