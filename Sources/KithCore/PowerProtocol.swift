import Foundation

public enum PowerService {
    public static let clientIdentifier = "app.trykith.kith"
    public static let name = "app.trykith.kith.power"
    public static let plistName = "app.trykith.kith.power.plist"
}

@objc public protocol PowerServiceProtocol {
    func status(withReply reply: @escaping (Bool, String) -> Void)
    func acquire(leaseID: String, withReply reply: @escaping (Bool, String) -> Void)
    func renew(leaseID: String, withReply reply: @escaping (Bool, String) -> Void)
    func release(leaseID: String, withReply reply: @escaping (Bool, String) -> Void)
    func perform(action: String, withReply reply: @escaping (Bool, String) -> Void)
}
