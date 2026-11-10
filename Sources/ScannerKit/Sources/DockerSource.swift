import Foundation

/// Reads Docker usage through the CLI. Docker data is stored inside a VM disk image, so it is never touched as files.
enum DockerSource {
    struct SystemDF: Decodable {
        var Images: [Image]?
        var Containers: [Container]?
        var Volumes: [Volume]?
        var BuildCache: [Cache]?
    }

    struct Image: Decodable {
        var Containers: String
        var CreatedAt: String?
        var ID: String
        var Repository: String
        var Tag: String
        var UniqueSize: String
        var Size: String
    }

    struct Container: Decodable {
        var ID: String
        var Image: String?
        var Names: String?
        var State: String?
        var Status: String?
        var Size: String?
        var CreatedAt: String?
    }

    struct Volume: Decodable {
        var Name: String
        var Links: String
        var Size: String
        var Labels: String?
    }

    struct Cache: Decodable {
        var InUse: String?
        var Size: String
        var Shared: String?
    }

    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        let orbstackDisk = Paths.expand("~/Library/Group Containers/HUAQ24HBR6.dev.orbstack", home: ctx.options.home)
        let dockerDesktopDisk = Paths.expand("~/Library/Containers/com.docker.docker", home: ctx.options.home)
        var items: [ScanItem] = []

        for (path, title, app) in [
            (orbstackDisk, String(localized: "OrbStack virtual machine disk image", bundle: .scannerKit), "OrbStack"),
            (dockerDesktopDisk, String(localized: "Docker Desktop data", bundle: .scannerKit), "Docker Desktop"),
        ] where Paths.exists(path) {
            await ctx.claims.claimAll([path])
            let info = SizeCalculator.measure(path)
            items.append(ScanItem(
                id: "docker.vm-disk:\(path)", category: .docker, title: title, app: app,
                description: String(localized: "A single disk image file that holds all containers, images, volumes and Linux machines. The items above are part of it. It is not removed as a file: removing images and volumes frees space inside it, and \(app) returns that space to macOS automatically.", bundle: .scannerKit),
                safety: .userData, sizeBytes: info.allocatedBytes, lastModified: info.newestModification, paths: [path],
                ownerBundleIDs: app == "OrbStack" ? ["dev.kdrag0n.MacVirt"] : ["com.docker.docker"]
            ))
        }

        let output: CommandOutput
        do {
            output = try await ReadOnlyCommand.run(["docker", "system", "df", "-v", "--format", "{{json .}}"], timeout: 120)
        } catch {
            if !items.isEmpty { await ctx.warnings.add(String(localized: "Docker: could not read data (\(String(describing: error))). Is OrbStack running?", bundle: .scannerKit)) }
            return items
        }
        guard output.status == 0 else {
            await ctx.warnings.add(String(localized: "Docker is not responding: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)). Start OrbStack to see images and volumes.", bundle: .scannerKit))
            return items
        }
        guard let df = try? JSONDecoder().decode(SystemDF.self, from: output.stdout) else {
            await ctx.warnings.add(String(localized: "Docker: unrecognized response format.", bundle: .scannerKit))
            return items
        }
        return parse(df) + items
    }

    static func parse(_ df: SystemDF) -> [ScanItem] {
        var items: [ScanItem] = []
        let owner = ["dev.kdrag0n.MacVirt"]

        let unusedImages = (df.Images ?? []).filter { $0.Containers == "0" }.map { image -> ScanItem in
            let named = image.Repository != "<none>" && image.Tag != "<none>"
            let ref = named ? "\(image.Repository):\(image.Tag)" : image.ID
            let shortID = String(image.ID.replacingOccurrences(of: "sha256:", with: "").prefix(12))
            return ScanItem(
                id: "docker.image:\(image.ID):\(ref)", category: .docker,
                title: named ? ref : String(localized: "<unnamed> \(shortID)", bundle: .scannerKit), app: "Docker",
                description: String(localized: "A Docker image that no container uses. The size counts only its unique part; layers shared with other images stay.", bundle: .scannerKit),
                regeneration: String(localized: "Pull it again (docker pull) or build it (docker build).", bundle: .scannerKit),
                safety: .regenerable, sizeBytes: parseSize(image.UniqueSize), lastModified: parseDate(image.CreatedAt),
                action: .command(argv: ["docker", "image", "rm", ref]), ownerBundleIDs: owner,
                note: String(localized: "Full image size: \(image.Size)", bundle: .scannerKit)
            )
        }
        if let group = makeGroup(
            id: "docker.images.unused", title: String(localized: "Images without containers", bundle: .scannerKit),
            description: String(localized: "Docker images that no container uses: old project builds and base images.", bundle: .scannerKit),
            safety: .regenerable, children: unusedImages
        ) { items.append(group) }

        let stopped = (df.Containers ?? []).filter { ($0.State ?? "running") != "running" }.map { c -> ScanItem in
            ScanItem(
                id: "docker.container:\(c.ID)", category: .docker,
                title: c.Names ?? String(c.ID.prefix(12)), app: "Docker",
                description: String(localized: "Stopped container (image \(c.Image ?? "?")). Removing it loses changes written to its file system but does not touch volumes.", bundle: .scannerKit),
                safety: .caution, sizeBytes: parseSize(c.Size ?? "0B"), lastModified: parseDate(c.CreatedAt),
                action: .command(argv: ["docker", "container", "rm", c.ID]), ownerBundleIDs: owner, note: c.Status
            )
        }
        if let group = makeGroup(
            id: "docker.containers.stopped", title: String(localized: "Stopped containers", bundle: .scannerKit),
            description: String(localized: "Containers that are not running.", bundle: .scannerKit), safety: .caution, children: stopped
        ) { items.append(group) }

        let unusedVolumes = (df.Volumes ?? []).filter { $0.Links == "0" }
        let anonymous = unusedVolumes.filter(isAnonymous).map { v in
            ScanItem(
                id: "docker.volume:\(v.Name)", category: .docker, title: String(v.Name.prefix(16)) + "…", app: "Docker",
                description: String(localized: "An unnamed volume not attached to any container. Usually left over from docker run or compose down without -v, but it may hold test database data.", bundle: .scannerKit),
                regeneration: String(localized: "The contents cannot be restored; the container will create a new, empty volume.", bundle: .scannerKit),
                safety: .caution, sizeBytes: parseSize(v.Size), action: .command(argv: ["docker", "volume", "rm", v.Name]),
                ownerBundleIDs: owner, note: v.Name
            )
        }
        if let group = makeGroup(
            id: "docker.volumes.anonymous", title: String(localized: "Anonymous volumes without containers", bundle: .scannerKit),
            description: String(localized: "Volumes with random names, not attached to any container.", bundle: .scannerKit), safety: .caution, children: anonymous
        ) { items.append(group) }

        let named = unusedVolumes.filter { !isAnonymous($0) }.map { v in
            let project = label("com.docker.compose.project", in: v.Labels)
            return ScanItem(
                id: "docker.volume:\(v.Name)", category: .docker, title: v.Name, app: "Docker",
                description: String(localized: "A named volume not attached to any container right now. Such volumes usually hold databases and project files; having no container does not mean they are no longer needed.", bundle: .scannerKit),
                regeneration: String(localized: "The contents cannot be restored without a backup.", bundle: .scannerKit),
                safety: .caution, sizeBytes: parseSize(v.Size), action: .command(argv: ["docker", "volume", "rm", v.Name]),
                ownerBundleIDs: owner, note: project.map { String(localized: "docker compose project: \($0)", bundle: .scannerKit) }
            )
        }
        if let group = makeGroup(
            id: "docker.volumes.named", title: String(localized: "Named volumes without containers (databases)", bundle: .scannerKit),
            description: String(localized: "Named volumes without a container. Check each one before removing it.", bundle: .scannerKit), safety: .caution, children: named
        ) { items.append(group) }

        let cacheBytes = (df.BuildCache ?? []).filter { $0.InUse == "false" && $0.Shared == "false" }.reduce(Int64(0)) { $0 + parseSize($1.Size) }
        if cacheBytes > 0 {
            items.append(ScanItem(
                id: "docker.buildcache", ruleID: "docker.buildcache", category: .docker, title: String(localized: "Build cache (BuildKit)", bundle: .scannerKit), app: "Docker",
                description: String(localized: "Unused, unshared docker build layers. The size is an estimate; the command may reclaim less. Project data is not affected.", bundle: .scannerKit),
                regeneration: String(localized: "Rebuilt by later builds, which will be slower.", bundle: .scannerKit),
                safety: .safe, sizeBytes: cacheBytes, action: .command(argv: ["docker", "builder", "prune", "--force"]),
                ownerBundleIDs: owner
            ))
        }
        return items
    }

    private static func makeGroup(id: String, title: String, description: String, safety: Safety, children: [ScanItem]) -> ScanItem? {
        let sorted = children.filter { $0.sizeBytes > 0 }.sorted { $0.sizeBytes > $1.sizeBytes }
        guard !sorted.isEmpty else { return nil }
        return ScanItem(
            id: id, ruleID: id, category: .docker, title: title, app: "Docker", description: description, safety: safety,
            sizeBytes: sorted.reduce(0) { $0 + $1.sizeBytes }, lastModified: sorted.compactMap(\.lastModified).max(),
            ownerBundleIDs: ["dev.kdrag0n.MacVirt"], children: sorted
        )
    }

    static func isAnonymous(_ v: Volume) -> Bool {
        (v.Labels ?? "").contains("com.docker.volume.anonymous")
            || v.Name.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    static func label(_ key: String, in labels: String?) -> String? {
        guard let labels else { return nil }
        for pair in labels.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key { return String(kv[1]) }
        }
        return nil
    }

    /// Docker prints decimal units ("1.826GB", "92B", "81.92kB").
    static func parseSize(_ s: String) -> Int64 {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let idx = trimmed.firstIndex(where: { $0.isLetter }) else { return Int64(Double(trimmed) ?? 0) }
        let number = Double(trimmed[..<idx]) ?? 0
        let multiplier: Double = switch trimmed[idx...].uppercased() {
        case "B": 1
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 0
        }
        return Int64(number * multiplier)
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let parts = s.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        return f.date(from: parts[0...2].joined(separator: " "))
    }
}
