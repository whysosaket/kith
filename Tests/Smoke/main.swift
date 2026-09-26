import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

var store = SessionStore()
let id = "kith-smoke-session"
let start = AgentEvent(source: .codex, sessionID: id, turnID: "turn-1", kind: .turnStarted)
check(store.apply(start, surface: .codexCLI) == .running, "turn starts running")
check(store.apply(start, surface: .codexCLI) == nil, "replayed event is ignored")
check(store.apply(AgentEvent(source: .codex, sessionID: id, turnID: "turn-1",
                             kind: .stopCandidate), surface: .codexCLI) == nil,
      "stop hook is only a candidate")
check(!store.allSafeToFinish, "stop hook cannot trigger power action")

_ = store.apply(AgentEvent(source: .codex, sessionID: id, turnID: "turn-1",
                           kind: .attentionOpened, attentionID: "approval-1"), surface: .codexCLI)
check(!store.allSafeToFinish, "approval blocks finish")
_ = store.reconcile(AgentSession(source: .codex, surface: .codexCLI,
                                 sessionID: id, turnID: "turn-1", status: .running))
check(store.sessions["codex:\(id)"]?.status == .needsInput,
      "running index cannot clear unresolved approval")
_ = store.apply(AgentEvent(source: .codex, sessionID: id, turnID: "turn-1",
                           kind: .attentionResolved, attentionID: "approval-1"), surface: .codexCLI)
check(store.sessions["codex:\(id)"]?.status == .running, "matching approval clears prompt")
_ = store.reconcile(AgentSession(source: .codex, surface: .codexCLI,
                                 sessionID: id, turnID: "turn-1", status: .ready))
check(store.allSafeToFinish, "confirmed completion is safe")
_ = store.apply(AgentEvent(source: .codex, sessionID: id, kind: .sessionEnded,
                           timestamp: Date().addingTimeInterval(86_400)), surface: .codexCLI)
check(store.sessions["codex:\(id)"]!.lastActivity <= Date(), "future event timestamps are capped")

var unknown = SessionStore()
_ = unknown.reconcile(AgentSession(source: .claude, surface: .claudeDesktop,
                                   sessionID: "unknown", status: .unavailable))
check(!unknown.allSafeToFinish, "unknown state blocks finish")
var persisted = SessionStore()
_ = persisted.reconcile(AgentSession(source: .claude, surface: .claudeCLI,
                                    sessionID: "persist", projectPath: "/private/project",
                                    title: "secret prompt", status: .running))
let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("kith-snapshot-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: snapshotURL) }
try persisted.save(to: snapshotURL)
let snapshotText = try String(contentsOf: snapshotURL, encoding: .utf8)
check(!snapshotText.contains("secret prompt") && !snapshotText.contains("/private/project"),
      "snapshot excludes titles and paths")
check(SessionStore.load(from: snapshotURL).sessions["claude:persist"]?.status == .unavailable,
      "restored running work requires a fresh scan")
var missing = SessionStore()
_ = missing.reconcile(AgentSession(source: .codex, surface: .codexCLI,
                                   sessionID: "lost", status: .running,
                                   lastActivity: Date().addingTimeInterval(-30)))
missing.markMissing(seenIDs: [], olderThan: Date().addingTimeInterval(-10))
check(missing.sessions["codex:lost"]?.status == .unavailable && !missing.allSafeToFinish,
      "missing active session becomes unknown and blocks finish")

let parsed = EventParser.parse(source: .claude, payload: [
    "session_id": "test", "hook_event_name": "PermissionRequest", "cwd": "/tmp/project",
    "tool_input": ["secret": "never stored"]
])
check(parsed?.kind == .attentionOpened, "permission hook parsed")
let data = try JSONEncoder().encode(parsed)
check(!String(decoding: data, as: UTF8.self).contains("secret"), "tool input was discarded")

let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("kith-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: fakeHome) }
let existing: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo other"]]]]]]
let files = FileManager.default
let claudeLink = fakeHome.appendingPathComponent(".claude/settings.json")
let claudeTarget = fakeHome.appendingPathComponent("dotfiles/claude-settings.json")
let codexFile = fakeHome.appendingPathComponent(".codex/hooks.json")
for url in [claudeLink, claudeTarget, codexFile] {
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
}
for url in [claudeTarget, codexFile] { try JSONSerialization.data(withJSONObject: existing).write(to: url) }
try files.createSymbolicLink(at: claudeLink, withDestinationURL: claudeTarget)
try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: codexFile.path)
let eventExecutable = URL(fileURLWithPath: "/Applications/Kith.app/Contents/MacOS/kith-event")
try HookInstaller.install(executable: eventExecutable, home: fakeHome)
check(HookInstaller.isInstalled(executable: eventExecutable, home: fakeHome), "both hook sets installed")
check((try? files.destinationOfSymbolicLink(atPath: claudeLink.path)) == claudeTarget.path,
      "install keeps a symlinked settings file linked")
check(files.fileExists(atPath: claudeTarget.path + ".kith-backup") &&
      files.fileExists(atPath: codexFile.path + ".kith-backup"), "install backs up the original files")
let codexText = try String(contentsOf: codexFile, encoding: .utf8)
check(!codexText.contains("\\/"), "install keeps slashes unescaped")
let codexPermissions = try files.attributesOfItem(atPath: codexFile.path)[.posixPermissions] as? Int
check(codexPermissions == 0o644, "install keeps existing permissions")
try HookInstaller.uninstall(executable: eventExecutable, home: fakeHome)
for path in [".claude/settings.json", ".codex/hooks.json"] {
    let file = fakeHome.appendingPathComponent(path)
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let hooks = root["hooks"] as! [String: Any]
    let groups = hooks["Stop"] as! [[String: Any]]
    check(groups.count == 1, "uninstall kept other hook groups")
    check(((groups[0]["hooks"] as! [[String: Any]])[0]["command"] as? String) == "echo other",
          "uninstall kept unrelated hook")
}
print("Kith core smoke checks passed")
let current = LocalReconciler.scan()
print("Local scan: \(current.sessions.count) recent sessions, unavailable: " +
      current.unavailable.map(\.title).sorted().joined(separator: ", "))
let counts = Dictionary(grouping: current.sessions, by: \.status).mapValues(\.count)
print("States: running \(counts[.running, default: 0]), input \(counts[.needsInput, default: 0]), " +
      "ready \(counts[.ready, default: 0]), unknown \(counts[.unavailable, default: 0])")
