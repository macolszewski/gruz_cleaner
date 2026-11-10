import AppKit
import ScannerKit
import SwiftUI

extension Safety {
    var color: Color {
        switch self {
        case .safe: .green
        case .regenerable: .blue
        case .caution: .orange
        case .userData: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .regenerable: "arrow.triangle.2.circlepath"
        case .caution: "exclamationmark.triangle"
        case .userData: "lock"
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety
    var compact = false

    var body: some View {
        Label(safety.title, systemImage: safety.symbol)
            .labelStyle(.titleAndIcon)
            .font(compact ? .caption2 : .caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(safety.color)
            .background(safety.color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct PermanentBadge: View {
    var body: some View {
        Label("Permanent deletion", systemImage: "flame")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct SizeBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.opacity(0.75))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleIDs: [String]) -> NSImage? {
        for id in bundleIDs {
            if let cached = cache[id] { return cached }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                cache[id] = image
                return image
            }
        }
        return nil
    }
}

struct ItemIcon: View {
    let item: ScanItem
    var size: CGFloat = 20

    var body: some View {
        if let image = AppIcons.icon(for: item.ownerBundleIDs) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: item.isGroup ? "folder" : item.category.symbol)
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
enum Formatters {
    /// The user's locale in the language the interface resolved to. A per-app language does not
    /// always reach `Locale.current`, and dates must not mix languages with the surrounding text.
    static let locale: Locale = {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: Localization.current)
        return Locale(components: components)
    }()

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .full
        return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func age(_ date: Date?) -> String {
        guard let date else { return String(localized: "no date") }
        if abs(date.timeIntervalSinceNow) < 60 { return String(localized: "just now") }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// Byte delta with an explicit sign, e.g. "+1.2 GB" or "−300 MB".
    static func signedBytes(_ delta: Int64) -> String {
        (delta >= 0 ? "+" : "\u{2212}") + abs(delta).formattedBytes
    }

    /// Scan duration in whole seconds, e.g. "35 sec" or "35 s".
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated).locale(locale))
    }
}

/// Tri-state checkbox (nil = mixed).
struct TriStateCheckbox: View {
    let state: Bool?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(enabled ? (state == false ? Color.secondary : Color.accentColor) : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? Text("Select for removal") : Text("This item cannot be removed in GRUZ"))
    }

    private var symbol: String {
        guard enabled else { return "lock.square" }
        switch state {
        case true: return "checkmark.square.fill"
        case false: return "square"
        case nil: return "minus.square.fill"
        }
    }
}
