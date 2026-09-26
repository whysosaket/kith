import Foundation

public enum PowerService {
    public static let clientIdentifier = "dev.kith.app"
    public static let name = "dev.kith.power"
    public static let plistName = "dev.kith.power.plist"
}

@objc public protocol PowerServiceProtocol {
    func status(withReply reply: @escaping (Bool, String) -> Void)
    func acquire(leaseID: String, withReply reply: @escaping (Bool, String) -> Void)
    func renew(leaseID: String, withReply reply: @escaping (Bool, String) -> Void)
    func release(leaseID: String, withReply reply: @escaping (Bool, String) -> Void)
    func perform(action: String, withReply reply: @escaping (Bool, String) -> Void)
}
