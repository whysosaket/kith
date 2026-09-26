import Foundation

public enum KithPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kith", isDirectory: true)
    }

    public static var spool: URL { support.appendingPathComponent("events", isDirectory: true) }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var sessionState: URL { support.appendingPathComponent("sessions.json") }
    public static var socket: URL { support.appendingPathComponent("event.sock") }

    public static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: spool.path)
    }
}
