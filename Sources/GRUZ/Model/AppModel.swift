import AppKit
import CleanerKit
import Foundation
import Observation
import ScannerKit

struct CategorySummary: Identifiable {
    var category: ScannerKit.Category
    var removableBytes: Int64
    var totalBytes: Int64
    var itemCount: Int
    var id: String { category.id }
}

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let claudeMemory = ClaudeMemoryModel()
    var showingClaudeMemory = false
    private(set) var catalog: RuleCatalog?
    private(set) var catalogError: String?

    private(set) var result: ScanResult? {
        didSet {
            resultVersion &+= 1
            itemIndex = nil
            visibleCache = nil
        }
    }
    private(set) var isScanning = false
    private(set) var activeStages: [ScanStage] = []
    private(set) var resultIsCached = false
    /// True while a confirmed cleaning plan runs; the app must not be relaunched then.
    private(set) var isCleaning = false

    var selectedCategory: ScannerKit.Category? = .docker
    var focusedItemID: String?
    var searchText = ""
    var growthOnly = false
    /// Selected leaf ids, across all categories.
    var selection: Set<String> = []
    /// Trash items the user switched to permanent deletion in the review sheet.
    var forcePermanent: Set<String> = []

    /// Checked live: a cached scan result may predate granting the permission.
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted()
    /// True when showing fictional data for screenshots (debug builds only): never scans or removes.
    private(set) var isDemo = false
    private var scanTask: Task<Void, Never>?
    private var partialResult: ScanResult?

    /// Derived from `result` and the filters; rebuilt only when they change, not on every view update.
    @ObservationIgnored private var resultVersion = 0
    @ObservationIgnored private var itemIndex: [String: ScanItem]?
    @ObservationIgnored private var visibleCache: (key: VisibleKey, byCategory: [ScannerKit.Category: [ScanItem]])?
    /// Reads and writes `last-scan.json` in order, away from the main thread.
    @ObservationIgnored private let cacheQueue = DispatchQueue(label: "GRUZ last scan", qos: .utility)

    init() {
        do {
            catalog = try RuleCatalog.builtIn()
        } catch {
            catalogError = String(describing: error)
        }
        #if DEBUG
        if let scenario = ScreenshotScenario.current {
            isDemo = true
            scenario.configure(self)
            return
        }
        #endif
        loadCachedResult()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFullDiskAccess() }
        }
    }

    #if DEBUG
    /// Shows fictional results instead of scanning (screenshots only).
    func showDemo(_ demo: ScanResult) {
        result = demo
        resultIsCached = false
        hasFullDiskAccess = true
    }
    #endif

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    // MARK: Scanning

    func scan() {
        // A scan during removal would show items that are being removed and could be selected again.
        guard let catalog, canScan, !isDemo else { return }
        refreshFullDiskAccess()
        isScanning = true
        activeStages = []
        let options = ScanOptions(projectRoots: settings.projectRoots, unrecognizedMinimumMB: settings.unrecognizedMinimumMB)
        partialResult = nil
        scanTask = Task {
            let scanner = Scanner(catalog: catalog, options: options)
            let result = await scanner.scan(onStage: { stage, done in
                Task { @MainActor [weak self] in
                    guard let self, self.isScanning else { return }
                    if done { self.activeStages.removeAll { $0 == stage } } else { self.activeStages.append(stage) }
                }
            }, onItems: { items in
                Task { @MainActor [weak self] in
                    guard let self, self.isScanning, !items.isEmpty else { return }
                    // Replace the cached result with live results as soon as the first stage lands.
                    if self.partialResult == nil {
                        self.partialResult = ScanResult(
                            items: [], warnings: [], startedAt: Date(), finishedAt: Date(),
                            freeBytes: DiskSpace.available(), totalBytes: DiskSpace.total(),
                            hasFullDiskAccess: self.hasFullDiskAccess
                        )
                    }
                    self.partialResult?.items += items
                    self.result = self.partialResult
                    self.resultIsCached = false
                }
            })
            let historyDirectory = self.cacheURL.deletingLastPathComponent()
            let roots = options.projectRoots
            let (annotated, index) = await Task.detached {
                let annotated = UsageHistoryStore.update(result, roots: roots, directory: historyDirectory)
                return (annotated, annotated.index)
            }.value
            self.result = annotated
            self.itemIndex = index
            self.partialResult = nil
            self.resultIsCached = false
            self.isScanning = false
            self.activeStages = []
            // Drop selections that no longer exist.
            self.selection = self.selection.filter { index[$0] != nil }
            self.saveCachedResult(annotated)
        }
    }

    // MARK: Filtering

    /// Items of a category after applying age thresholds and search; groups keep only visible children.
    func visibleItems(in category: ScannerKit.Category) -> [ScanItem] {
        guard let result else { return [] }
        // Reading the inputs here also registers them for observation when the cached answer is used.
        let key = VisibleKey(
            resultVersion: resultVersion, searchText: searchText, growthOnly: growthOnly,
            ageFilterEnabled: settings.ageFilterEnabled, ageFilterDays: settings.ageFilterDays,
            ruleAgeOverrides: settings.ruleAgeOverrides, hour: Int(Date().timeIntervalSince1970 / 3600)
        )
        if visibleCache?.key != key { visibleCache = (key, [:]) }
        if let cached = visibleCache?.byCategory[category] { return cached }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let items = result.items(in: category).compactMap { filtered($0, query: query) }
        let sorted: [ScanItem]
        if growthOnly {
            // Each item's growth sums its leaves; computing it once keeps the sort from repeating that.
            sorted = items.map { ($0, growthAmount($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
        } else {
            sorted = items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
        visibleCache?.byCategory[category] = sorted
        return sorted
    }

    private struct VisibleKey: Equatable {
        var resultVersion: Int
        var searchText: String
        var growthOnly: Bool
        var ageFilterEnabled: Bool
        var ageFilterDays: Int
        var ruleAgeOverrides: [String: Int]
        /// Age thresholds compare with the current time, so the answer is also refreshed every hour.
        var hour: Int
    }

    private func growthAmount(_ item: ScanItem) -> Int64 {
        item.leaves.reduce(0) { $0 + max(0, $1.growth?.deltaBytes ?? $1.rustArtifact?.recentBytes ?? 0) }
    }

    private func filtered(_ item: ScanItem, query: String) -> ScanItem? {
        if item.isGroup {
            let parentMatches = !query.isEmpty && matches(item, query)
            let children = item.children.compactMap { filtered($0, query: parentMatches ? "" : query) }
            guard !children.isEmpty else { return nil }
            var copy = item
            copy.children = children
            copy.sizeBytes = children.reduce(0) { $0 + $1.sizeBytes }
            return copy
        }
        if !query.isEmpty, !matches(item, query) { return nil }
        if growthOnly {
            guard (item.growth?.deltaBytes ?? 0) > 0 || (item.growth == nil && (item.rustArtifact?.recentBytes ?? 0) > 0) else { return nil }
        } else if !passesAge(item) { return nil }
        return item
    }

    private func matches(_ item: ScanItem, _ query: String) -> Bool {
        item.title.lowercased().contains(query)
            || (item.app?.lowercased().contains(query) ?? false)
            || item.paths.contains { $0.lowercased().contains(query) }
            || (item.note?.lowercased().contains(query) ?? false)
    }

    func ageThreshold(for item: ScanItem) -> Int? {
        settings.threshold(for: ItemThresholdInput(ruleID: item.ruleID, defaultAgeDays: item.defaultAgeDays))
    }

    private func passesAge(_ item: ScanItem) -> Bool {
        guard let days = ageThreshold(for: item) else { return true }
        guard let modified = item.lastModified else { return true }
        return modified < Date().addingTimeInterval(-Double(days) * 86_400)
    }

    var summaries: [CategorySummary] {
        ScannerKit.Category.allCases.compactMap { category in
            let items = visibleItems(in: category)
            guard !items.isEmpty else { return nil }
            let leaves = items.flatMap(\.leaves)
            return CategorySummary(
                category: category,
                removableBytes: leaves.filter(\.isSelectable).reduce(0) { $0 + $1.sizeBytes },
                totalBytes: items.reduce(0) { $0 + $1.sizeBytes },
                itemCount: leaves.count
            )
        }
    }

    var hiddenByAgeCount: Int {
        guard let result else { return 0 }
        return result.items.flatMap(\.leaves).filter { !passesAge($0) }.count
    }

    // MARK: Selection

    func item(id: String?) -> ScanItem? {
        guard let id, let result else { return nil }
        if itemIndex == nil { itemIndex = result.index }
        return itemIndex?[id]
    }

    func selectionState(of item: ScanItem, visible: ScanItem) -> Bool? {
        let leaves = visible.leaves.filter(\.isSelectable)
        guard !leaves.isEmpty else { return false }
        let selected = leaves.filter { selection.contains($0.id) }.count
        if selected == 0 { return false }
        return selected == leaves.count ? true : nil
    }

    func toggle(_ visible: ScanItem) {
        let ids = visible.leaves.filter(\.isSelectable).map(\.id)
        if ids.allSatisfy(selection.contains) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    /// Selected leaves that are still visible (hidden ones are never acted on).
    var selectedLeaves: [ScanItem] {
        ScannerKit.Category.allCases.flatMap { visibleItems(in: $0) }.flatMap(\.leaves).filter { selection.contains($0.id) }
    }

    /// Count and size of the selection from one pass over the visible items.
    var selectionSummary: (count: Int, bytes: Int64) {
        let leaves = selectedLeaves
        return (leaves.count, leaves.reduce(0) { $0 + $1.sizeBytes })
    }

    func clearSelection() {
        selection.removeAll()
        forcePermanent.removeAll()
    }

    // MARK: Cleaning

    func makePlan() -> CleaningPlan {
        CleaningPlan.make(from: selectedLeaves, forcePermanent: forcePermanent)
    }

    var executor: CleaningExecutor {
        #if DEBUG
        if isDemo { return DemoExecutor.make() }
        #endif
        return .live(projectRoots: settings.projectRoots)
    }

    /// True while removing data; quitting must wait.
    var isBusy: Bool { isCleaning || claudeMemory.isRunning }

    /// A new scan may start: none is running and nothing is being removed.
    var canScan: Bool { !isScanning && !isCleaning }

    func execute(_ plan: CleaningPlan, confirmation: CleaningConfirmation) async -> CleaningReport {
        guard !isDemo else { return CleaningReport() }
        guard !isCleaning, !isScanning else {
            return .skippingAll(plan, reason: String(localized: "Wait until the scan finishes, then review the selection again."))
        }
        isCleaning = true
        let report = await executor.execute(plan, confirmation: confirmation)
        isCleaning = false
        // Done items leave the list; a partly removed one stays, reduced to the paths still on disk.
        var done: Set<String> = []
        var remaining: [String: [String]] = [:]
        for r in report.results {
            switch r.status {
            case .done: done.insert(r.operation.id)
            case .partial: remaining[r.operation.id] = r.remainingPaths
            case .skipped, .failed: break
            }
        }
        selection.subtract(done.union(remaining.keys))
        forcePermanent.subtract(done)
        if var current = result {
            current.items = current.items.compactMap { applying(done: done, remaining: remaining, to: $0) }
            result = current
        }
        return report
    }

    private func applying(done: Set<String>, remaining: [String: [String]], to item: ScanItem) -> ScanItem? {
        if done.contains(item.id) { return nil }
        var copy = item
        if let paths = remaining[item.id] { copy.paths = paths }
        guard item.isGroup else { return copy }
        copy.children = item.children.compactMap { applying(done: done, remaining: remaining, to: $0) }
        if copy.children.isEmpty { return nil }
        copy.sizeBytes = copy.children.reduce(0) { $0 + $1.sizeBytes }
        return copy
    }

    // MARK: Cache

    private var cacheURL: URL {
        URL(fileURLWithPath: Paths.home).appendingPathComponent("Library/Application Support/GRUZ/last-scan.json")
    }

    /// Decodes the last result on the cache queue and shows it unless a scan has already replaced it.
    private func loadCachedResult() {
        let url = cacheURL
        let rescanNote = String(localized: "Scan again to choose Rust profiles safely.")
        cacheQueue.async {
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Titles and descriptions are stored already resolved, so a scan made in another language is stale.
            guard var cached = try? decoder.decode(ScanResult.self, from: data), Self.matchesCurrentLanguage(cached) else { return }
            func disableLegacyRust(_ item: ScanItem) -> ScanItem {
                var copy = item
                copy.children = item.children.map(disableLegacyRust)
                if item.ruleID == "artifact.rust-target", item.rustArtifact == nil {
                    copy.action = nil
                    copy.note = rescanNote
                }
                return copy
            }
            cached.items = cached.items.map(disableLegacyRust)
            let loaded = cached
            Task { @MainActor [weak self] in
                guard let self, self.result == nil, !self.isScanning else { return }
                self.result = loaded
                self.resultIsCached = true
            }
        }
    }

    private nonisolated static func matchesCurrentLanguage(_ result: ScanResult) -> Bool {
        result.language == Localization.current
    }

    /// Writes run in the order they were asked for, so an older result never replaces a newer one.
    private func saveCachedResult(_ result: ScanResult) {
        let url = cacheURL
        cacheQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(result) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
