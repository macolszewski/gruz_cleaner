import Darwin
import Foundation
import ScannerKit

/// Held while a Rust artifact is being removed; releasing it lets Cargo use the profile again.
public protocol RustRemovalLease: Sendable { func release() }

/// Confirms that a Rust artifact still matches the scan and that no build tool is using it.
public protocol RustRemovalChecking: Sendable {
    func acquire(_ artifact: RustArtifact, paths: [String]) throws -> any RustRemovalLease
}

/// Why a Rust artifact cannot be removed right now.
public struct RustRemovalError: Error, LocalizedError {
    /// Localized explanation shown to the user.
    public var message: String
    /// English form of `message` for the operation log.
    var logMessage: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
        logMessage = message
    }

    init(_ message: LocalizedMessage) {
        self.message = message.text
        logMessage = message.english
    }
}

private final class CargoLease: RustRemovalLease, @unchecked Sendable {
    private let mutex = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func release() {
        mutex.withLock { if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd); fd = -1 } }
    }
    deinit { release() }
}

/// Holds Cargo's existing profile lock through the removal, so no build can start while files
/// disappear. Never deletes the lock or the profile.
public struct SystemRustRemovalGuard: RustRemovalChecking {
    private let processListing: @Sendable () throws -> String
    public init(processListing: (@Sendable () throws -> String)? = nil) {
        self.processListing = processListing ?? { try Self.output("/bin/ps", ["-axo", "comm="]) }
    }

    public func acquire(_ artifact: RustArtifact, paths: [String]) throws -> any RustRemovalLease {
        let target = artifact.targetRoot
        let profile = artifact.profileRoot
        guard paths == [artifact.path], RustArtifacts.components.contains((artifact.path as NSString).lastPathComponent),
              (artifact.path as NSString).deletingLastPathComponent == profile,
              Paths.isWithin(profile, target), profile != target,
              Paths.exists(artifact.manifestPath ?? Paths.join((target as NSString).deletingLastPathComponent, "Cargo.toml")),
              (artifact.path as NSString).resolvingSymlinksInPath == artifact.path else {
            throw RustRemovalError(LocalizedMessage("The Rust artifact no longer matches the scan. Scan again."))
        }
        let lockPath = Paths.join(profile, ".cargo-lock")
        let fd = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RustRemovalError(LocalizedMessage("Cannot open the existing Cargo lock. Cleaning stopped.")) }
        let lease = CargoLease(fd)
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw RustRemovalError(LocalizedMessage("Cargo is using this profile. Wait for the build to finish and try again."))
            }
            let processes = try processListing()
            let names = processes.split(separator: "\n").map { (String($0) as NSString).lastPathComponent }
            if names.contains(where: { ["cargo", "rustc", "rust-analyzer", "lldb", "gdb", "sccache"].contains($0) }) {
                throw RustRemovalError(LocalizedMessage("Cargo, the Rust compiler, rust-analyzer or a debugger is running. Quit these tools before cleaning."))
            }
            if processes.split(separator: "\n").contains(where: { Paths.isWithin(String($0).trimmingCharacters(in: .whitespaces), profile) }) {
                throw RustRemovalError(LocalizedMessage("A program or test built in this profile is running. Quit it first."))
            }
            // The user approved exactly the files measured during the scan, nothing added since.
            let measured = RustArtifacts.measure(artifact.path, since: artifact.since)
            if let problem = measured.problem { throw RustRemovalError(problem) }
            guard measured.signature == artifact.signature else {
                throw RustRemovalError(LocalizedMessage("The artifacts changed since the scan. Scan again before removing them."))
            }
            // A directory replacement must not leave us holding an obsolete lock inode.
            var held = stat(), current = stat()
            guard fstat(fd, &held) == 0, lstat(lockPath, &current) == 0,
                  held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
                throw RustRemovalError(LocalizedMessage("The Cargo lock file was replaced. Scan again."))
            }
            return lease
        } catch { lease.release(); throw error }
    }

    private static func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else {
            throw RustRemovalError(LocalizedMessage("Could not check running processes. Cleaning stopped."))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
