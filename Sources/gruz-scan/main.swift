import Foundation
import ScannerKit

// Read-only report. This tool cannot remove anything: it has no access to CleanerKit.

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("-h") || arguments.contains("--help") {
    print("""
    gruz-scan: report of reclaimable disk space (read-only)

      --json             print the result as JSON
      --root <folder>    project folder to scan; repeatable. Default: the common project
                         folders that exist (~/Developer, ~/workspace, ~/Projects, ~/code, ...)
      --children         show nested items
      --stats            print counts of file system work to stderr
      --fs-width <n>     folder walks allowed at the same time (default \(IOPool.defaultWidth))
    """)
    exit(0)
}

var roots: [String] = []
var fileSystemWidth = IOPool.defaultWidth
var index = 0
while index < arguments.count {
    if arguments[index] == "--root", index + 1 < arguments.count {
        roots.append(arguments[index + 1])
        index += 1
    } else if arguments[index] == "--fs-width", index + 1 < arguments.count, let width = Int(arguments[index + 1]), width > 0 {
        fileSystemWidth = width
        index += 1
    }
    index += 1
}

let catalog: RuleCatalog
do {
    catalog = try RuleCatalog.builtIn()
} catch {
    FileHandle.standardError.write(Data("Rule catalog error: \(error)\n".utf8))
    exit(1)
}

let scanner = Scanner(catalog: catalog, options: ScanOptions(projectRoots: roots.isEmpty ? nil : roots, fileSystemWidth: fileSystemWidth))
let result = await scanner.scan { stage, done in
    if !done { FileHandle.standardError.write(Data("… \(stage.title)\n".utf8)) }
}
if arguments.contains("--stats") {
    let lines = ScanMetrics.shared.report.map { "\($0.name): \($0.value)" }
    FileHandle.standardError.write(Data((["scan time: \(String(format: "%.2f", result.finishedAt.timeIntervalSince(result.startedAt))) s"] + lines).joined(separator: "\n").utf8 + [10]))
}

if arguments.contains("--json") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(result))
    exit(0)
}

let showChildren = arguments.contains("--children")
func line(_ item: ScanItem, indent: Int) {
    let pad = String(repeating: "  ", count: indent)
    let size = item.sizeBytes.formattedBytes.padding(toLength: 10, withPad: " ", startingAt: 0)
    let mark = item.action?.isPermanent == true ? " [permanent]" : ""
    print("\(pad)\(size) \(item.title) · \(item.safety.title)\(mark)")
    if showChildren { item.children.forEach { line($0, indent: indent + 1) } }
}

for category in Category.allCases {
    let items = result.items(in: category).sorted { $0.sizeBytes > $1.sizeBytes }
    guard !items.isEmpty else { continue }
    let removable = items.flatMap(\.leaves).filter(\.isSelectable).reduce(Int64(0)) { $0 + $1.sizeBytes }
    print("\n== \(category.title)" + (category.isInformational ? "" : " (reclaimable: \(removable.formattedBytes))"))
    items.forEach { line($0, indent: 1) }
}
for warning in result.warnings { print("! \(warning)") }
if let free = result.freeBytes { print("\nFree space: \(free.formattedBytes)") }
if !result.hasFullDiskAccess { print("No Full Disk Access: the Trash, Mail and iPhone backups are not measured.") }
print(String(format: "Scan time: %.1f s", result.finishedAt.timeIntervalSince(result.startedAt)))
