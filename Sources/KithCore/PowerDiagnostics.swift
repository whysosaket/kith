import Foundation

public struct PowerDiagnostic: Codable, Sendable {
    public var date: Date
    public var event: String
}

public final class PowerDiagnostics {
    private let url: URL
    private var entries: [PowerDiagnostic]
    public init(url: URL) {
        self.url = url
        entries = (try? PowerStorage.read([PowerDiagnostic].self, from: url)) ?? []
    }
    public func record(_ event: String) {
        guard entries.last?.event != event else { return }
        entries.append(PowerDiagnostic(date: Date(), event: String(event.prefix(500))))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        try? PowerStorage.write(entries, to: url)
    }
    public var text: String {
        entries.map { "\($0.date.formatted(.iso8601)) \($0.event)" }.joined(separator: "\n")
    }
}
