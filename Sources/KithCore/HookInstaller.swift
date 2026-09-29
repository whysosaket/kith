import Foundation

public enum HookInstallerError: LocalizedError {
    case invalidConfiguration(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let url): "Cannot safely update \(url.path): it is not a JSON object."
        }
    }
}

public enum HookInstaller {
    private static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification",
        "PreToolUse", "PostToolUse", "Stop", "StopFailure", "SessionEnd"
    ]
    private static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop",
        "Interrupt", "SessionEnd"
    ]

    public static func install(executable: URL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try update(source: .claude, executable: executable, home: home, installing: true)
        try update(source: .codex, executable: executable, home: home, installing: true)
    }

    public static func uninstall(executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try update(source: .claude, executable: executable, home: home, installing: false)
        try update(source: .codex, executable: executable, home: home, installing: false)
    }

    public static func isInstalled(executable: URL,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        AgentSource.allCases.allSatisfy { source in
            let url = configURL(for: source, home: home)
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return true }
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hooks = root["hooks"] as? [String: Any] else { return false }
            let command = hookCommand(executable: executable, source: source)
            return events(for: source).allSatisfy { event in
                let groups = hooks[event] as? [[String: Any]] ?? []
                return groups.contains { group in
                    let handlers = group["hooks"] as? [[String: Any]] ?? []
                    return handlers.contains { ($0["command"] as? String) == command }
                }
            }
        }
    }

    private static func update(source: AgentSource, executable: URL,
                               home: URL, installing: Bool) throws {
        let url = configURL(for: source, home: home)
        let manager = FileManager.default
        // Creating an absent agent's folder would make the local scan treat that agent as installed.
        guard manager.fileExists(atPath: url.deletingLastPathComponent().path) else { return }
        let data = try? Data(contentsOf: url)
        let parsed = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard data == nil || parsed is [String: Any] else {
            throw HookInstallerError.invalidConfiguration(url)
        }
        var root = parsed as? [String: Any] ?? [:]
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else {
            throw HookInstallerError.invalidConfiguration(url)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = hookCommand(executable: executable, source: source)

        for event in events(for: source) {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                throw HookInstallerError.invalidConfiguration(url)
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.removeAll { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                let existing = handlers.first?["command"] as? String ?? ""
                return handlers.count == 1 &&
                    (existing == command || existing.hasSuffix("/Kith.app/Contents/MacOS/kith-event' \(source.rawValue)"))
            }
            if installing {
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": command, "timeout": 3]]
                ]
                if source == .claude && event == "PreToolUse" {
                    group["matcher"] = "AskUserQuestion"
                }
                groups.append(group)
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }

        // Write through symlinks so dotfile managers keep their link, and keep one pristine backup.
        let target = url.resolvingSymlinksInPath()
        try manager.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        let backup = target.appendingPathExtension("kith-backup")
        if data != nil && !manager.fileExists(atPath: backup.path) {
            try manager.copyItem(at: target, to: backup)
        }
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] ?? 0o600
        let output = try JSONSerialization.data(withJSONObject: root,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try output.write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
    }

    private static func configURL(for source: AgentSource, home: URL) -> URL {
        switch source {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    private static func events(for source: AgentSource) -> [String] {
        source == .claude ? claudeEvents : codexEvents
    }

    private static func hookCommand(executable: URL, source: AgentSource) -> String {
        let escaped = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)' \(source.rawValue)"
    }
}
