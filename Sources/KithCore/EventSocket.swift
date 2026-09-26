import Darwin
import Foundation

public final class EventSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceRead

    private init(descriptor: Int32, receive: @escaping @Sendable (AgentEvent) -> Void) {
        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = recv(descriptor, &bytes, bytes.count, 0)
            guard count > 0,
                  let event = try? JSONDecoder().decode(AgentEvent.self, from: Data(bytes.prefix(count))),
                  event.schemaVersion == 1 else { return }
            receive(event)
        }
        source.setCancelHandler {
            close(descriptor)
            unlink(KithPaths.socket.path)
        }
        source.resume()
    }

    deinit { source.cancel() }

    public static func listen(receive: @escaping @Sendable (AgentEvent) -> Void) throws -> EventSocket {
        try KithPaths.prepare()
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = addressForSocket()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { close(descriptor); throw POSIXError(.EADDRINUSE) }
        if errno != ENOENT && errno != ECONNREFUSED {
            close(descriptor)
            throw POSIXError(.EACCES)
        }
        unlink(KithPaths.socket.path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(descriptor); throw POSIXError(.EIO) }
        chmod(KithPaths.socket.path, 0o600)
        return EventSocket(descriptor: descriptor, receive: receive)
    }

    public static func send(_ event: AgentEvent) -> Bool {
        guard let data = try? JSONEncoder().encode(event), data.count <= 4096 else { return false }
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = addressForSocket()
        let sent = data.withUnsafeBytes { dataBytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, dataBytes.baseAddress, data.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        return sent == data.count
    }

    private static func addressForSocket() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(KithPaths.socket.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            precondition(path.count <= buffer.count)
            buffer.copyBytes(from: path)
        }
        return address
    }
}
