import AppKit
import CleanerKit
import Foundation
import Observation
import ScannerKit

@MainActor
@Observable
final class ClaudeMemoryModel {
    var date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    var dateRule: ClaudeMemoryDateRule = .before
    var project = ""
    var kinds: Set<ClaudeMemoryKind> = [.observations, .summaries, .prompts, .toolUses]
    var preview: ClaudeMemoryPreview?
    var error: String?
    var isLoading = false
    var isRunning = false
    var progress = ""
    var report: ClaudeMemoryReport?
    var reviewing = false
    var rebuildOnly = false
    private let cleaner = ClaudeMemoryCleaner()

    var filter: ClaudeMemoryFilter {
        ClaudeMemoryFilter(cutoff: Calendar.current.startOfDay(for: date), dateRule: dateRule,
                           project: project.isEmpty ? nil : project, kinds: kinds)
    }
    var isCurrent: Bool { preview?.filter == filter }
    var interrupted: Bool {
        preview.map { FileManager.default.fileExists(atPath: $0.location.maintenanceMarker.path) } ?? false
    }
    var maintenanceActive: Bool {
        preview.map { ClaudeMemoryCleaner.isMaintenanceActive(at: $0.location) } ?? false
    }

    func scan() {
        guard !isLoading, !isRunning else { return }
        isLoading = true
        error = nil
        let filter = filter
        Task {
            do {
                preview = try await Task.detached(priority: .userInitiated) {
                    let location = try ClaudeMemoryLocation.discover()
                    return try ClaudeMemoryReader(location: location).preview(filter: filter)
                }.value
            } catch {
                self.error = error.localizedDescription
                preview = nil
            }
            isLoading = false
        }
    }

    func review(rebuildOnly: Bool) {
        guard isCurrent, preview != nil else { return }
        self.rebuildOnly = rebuildOnly
        report = nil
        reviewing = true
    }

    func execute() {
        guard let preview, !isRunning else { return }
        isRunning = true
        Task {
            report = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true, rebuildOnly: rebuildOnly) { [weak self] message in
                await MainActor.run { self?.progress = message }
            }
            isRunning = false
        }
    }

    func closeReview() {
        reviewing = false
        if report != nil { scan() }
    }
}
