import Foundation

public enum ConnectivityEvent: Equatable, Sendable {
    case lost
    case restored(seconds: Int)
}

public struct ConnectivityState: Sendable {
    public private(set) var warning = false
    private var outage: Date?
    public init() {}

    public mutating func update(available: Bool?, active: Bool, now: Date) -> ConnectivityEvent? {
        guard active, let available else { outage = nil; warning = false; return nil }
        if available {
            defer { outage = nil; warning = false }
            if warning, let outage { return .restored(seconds: max(0, Int(now.timeIntervalSince(outage)))) }
        } else {
            if outage == nil { outage = now }
            if !warning, let outage, now.timeIntervalSince(outage) >= 5 {
                warning = true
                return .lost
            }
        }
        return nil
    }
}

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let components: [Int]
    public init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(part) else { return nil }
            parsed.append(number)
        }
        components = parsed
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}
