import Foundation

/// Lists simulator devices through `simctl`, the supported way to delete them.
enum SimulatorSource {
    struct DeviceList: Decodable {
        var devices: [String: [Device]]
    }

    struct Device: Decodable {
        var udid: String
        var name: String
        var state: String?
        var isAvailable: Bool?
        var lastBootedAt: String?
        var availabilityError: String?
    }

    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        let devicesDir = Paths.expand("~/Library/Developer/CoreSimulator/Devices", home: ctx.options.home)
        guard Paths.isDirectory(devicesDir) else { return [] }
        await ctx.claims.claimAll([devicesDir])

        guard let output = try? await ReadOnlyCommand.run(["xcrun", "simctl", "list", "devices", "--json"]),
              output.status == 0,
              let list = try? JSONDecoder().decode(DeviceList.self, from: output.stdout) else {
            await ctx.warnings.add(String(localized: "Simulators: could not read the device list (xcrun simctl).", bundle: .scannerKit))
            return []
        }
        let flat = list.devices.flatMap { runtime, devices in devices.map { (runtimeName(runtime), $0) } }
        let paths = flat.map { Paths.join(devicesDir, $0.1.udid) }
        let sizes = await SizeCalculator.measureAll(paths)
        let iso = ISO8601DateFormatter()

        let children = flat.compactMap { runtime, device -> ScanItem? in
            let path = Paths.join(devicesDir, device.udid)
            guard let info = sizes[path], info.allocatedBytes > 0 else { return nil }
            let available = device.isAvailable ?? true
            return ScanItem(
                id: "simulator:\(device.udid)", ruleID: "xcode.simulators", category: .xcode,
                title: "\(device.name) (\(runtime))", app: "Simulator",
                description: available
                    ? String(localized: "A simulator with the apps installed in it and their data. Removing it deletes the device; Xcode will create a new, empty one.", bundle: .scannerKit)
                    : String(localized: "A simulator for a runtime that is no longer installed. It cannot be started.", bundle: .scannerKit),
                regeneration: String(localized: "Add the device again in Xcode > Window > Devices and Simulators.", bundle: .scannerKit),
                safety: available ? .caution : .safe, sizeBytes: info.allocatedBytes,
                lastModified: device.lastBootedAt.flatMap { iso.date(from: $0) } ?? info.newestModification,
                paths: [path], action: .command(argv: ["xcrun", "simctl", "delete", device.udid]),
                ownerBundleIDs: ["com.apple.iphonesimulator"],
                note: device.state == "Booted" ? String(localized: "The simulator is running", bundle: .scannerKit) : nil
            ).measured(info)
        }.sorted { $0.sizeBytes > $1.sizeBytes }
        guard !children.isEmpty else { return [] }
        return [ScanItem(
            id: "xcode.simulators", ruleID: "xcode.simulators", category: .xcode, title: String(localized: "iOS simulators", bundle: .scannerKit), app: "Simulator",
            description: String(localized: "Simulator devices with their data.", bundle: .scannerKit), safety: .caution,
            sizeBytes: children.reduce(0) { $0 + $1.sizeBytes }, lastModified: children.compactMap(\.lastModified).max(),
            ownerBundleIDs: ["com.apple.iphonesimulator"], children: children
        )]
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5"
    static func runtimeName(_ id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        return "\(os) \(parts.dropFirst().joined(separator: "."))"
    }
}
