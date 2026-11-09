import Darwin
import Foundation
import KithCore

let usage = """
Usage:
  kith power status [--json]
  kith power start --for <duration> [--json]
  kith power extend --for <duration> [--json]
  kith power end [--json]
  kith power resume [--json]

Durations use whole seconds, minutes or hours, for example 30s, 15m or 2h.
Kith must be open. Manual wake periods cancel armed finish actions.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] || arguments.isEmpty {
    print(usage)
    exit(0)
}
let json = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

func emit(_ reply: PowerCommandReply) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(reply) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    } else if reply.ok {
        print(reply.message)
        if let state = reply.status {
            print("System wake hold: \(state.idleHoldActive ? "active" : "inactive")")
            print("Display wake hold: \(state.displayHoldActive ? "active" : "inactive")")
            if let deadline = state.deadline { print("Deadline: \(deadline.formatted(.iso8601))") }
            if let stopped = state.stopped { print(stopped.message) }
            print("Recovery: \(state.helper.recovery.title)")
            if let detail = state.helper.detail { print(detail) }
        }
    } else { FileHandle.standardError.write(Data((reply.message + "\n").utf8)) }
}

do {
    guard arguments.count >= 2, arguments[0] == "power", let kind = PowerCommandKind(rawValue: arguments[1]) else {
        throw PowerError.invalid(usage)
    }
    var seconds: TimeInterval?
    if kind == .start || kind == .extend {
        guard arguments.count == 4, arguments[2] == "--for", let duration = PowerDuration.parse(arguments[3]) else {
            throw PowerError.invalid("Provide --for with a duration between 1s and 24h")
        }
        seconds = duration
    } else if arguments.count != 2 { throw PowerError.invalid(usage) }
    let reply = try PowerCommandInbox.send(PowerCommand(kind: kind, seconds: seconds), directory: KithPaths.powerCommands)
    emit(reply)
    exit(reply.ok ? 0 : 1)
} catch {
    emit(PowerCommandReply(ok: false, message: error.localizedDescription))
    exit(1)
}
