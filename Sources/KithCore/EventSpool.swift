import Foundation

public enum EventSpool {
    public static func enqueue(_ event: AgentEvent) throws {
        try KithPaths.prepare()
        let existing = (try? FileManager.default.contentsOfDirectory(at: KithPaths.spool,
            includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "json" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate < rightDate
            } ?? []
        if existing.count >= 1_000 {
            for file in existing.prefix(existing.count - 999) { try? FileManager.default.removeItem(at: file) }
        }
        let data = try JSONEncoder().encode(event)
        guard data.count <= 4096 else { return }
        let temporary = KithPaths.spool.appendingPathComponent(".\(event.id.uuidString).tmp")
        let final = KithPaths.spool.appendingPathComponent("\(event.id.uuidString).json")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: final)
    }

    public static func drain(_ consume: (AgentEvent) -> Void) {
        for entry in pending() {
            consume(entry.event)
            try? FileManager.default.removeItem(at: entry.file)
        }
    }

    public static func pending(in directory: URL = KithPaths.spool) -> [(file: URL, event: AgentEvent)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { return [] }
        var result: [(file: URL, event: AgentEvent)] = []
        for file in files.prefix(1000) {
            guard let data = try? Data(contentsOf: file),
                  let event = try? JSONDecoder().decode(AgentEvent.self, from: data),
                  event.schemaVersion == 1 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            result.append((file, event))
        }
        return result
    }
}
