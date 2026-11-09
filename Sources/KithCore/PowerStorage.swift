import Darwin
import Foundation

public enum PowerStorage {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw PowerError.invalid("State is not a regular file: \(url.lastPathComponent)") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw PowerError.invalid("State is not a regular file: \(url.lastPathComponent)")
        }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw PowerError.invalid("State file exceeds 1 MiB") }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw PowerError.invalid("Refusing to replace non-regular state: \(url.lastPathComponent)")
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor); unlink(temporary.path) }
        let data = try JSONEncoder().encode(value)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    public static func lock(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PowerError.unavailable("Cannot open recovery lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PowerError.unavailable("Recovery pending: a power operation is still running")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

public struct CommandResult: Sendable {
    public var status: Int32
    public var output: String
}

/// Every subprocess has a bounded wait. A power writer inherits the recovery
/// lock as stdin, so even a helper crash cannot race a still-running writer.
public final class BoundedCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var unfinished: Process?

    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10,
                    inheritedLock: FileHandle? = nil) throws -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        if let unfinished, unfinished.isRunning {
            throw PowerError.unavailable("Power command \(unfinished.processIdentifier) is still running")
        }
        unfinished = nil
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inheritedLock ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var captured = Data()
        func drain() {
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<32 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                if captured.count < 1_048_576 { captured.append(contentsOf: buffer.prefix(min(count, 1_048_576 - captured.count))) }
            }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { drain(); Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                unfinished = process
                throw PowerError.unavailable("Power command \(process.processIdentifier) is still running; recovery will retry")
            }
            throw PowerError.unavailable("Command timed out: \(URL(fileURLWithPath: executable).lastPathComponent)")
        }
        drain()
        return CommandResult(status: process.terminationStatus, output: String(decoding: captured, as: UTF8.self))
    }
}
