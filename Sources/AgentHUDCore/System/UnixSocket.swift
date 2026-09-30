import Darwin
import Foundation
import Network
import os.log

/// A unix-domain stream socket between the running application and the short-lived processes a client's hooks start. A
/// request is one message, which its sender ends by closing its writing side; only the user can reach the socket.
public enum UnixSocket {
    /// Whether `path` fits a socket address, which holds about a hundred bytes.
    public static func fits(_ path: String) -> Bool { path.utf8.count < 104 }

    /// Connects to the socket at `path`; a write after the other side went away fails instead of raising SIGPIPE. Nil
    /// when there is no socket at `path` or nothing accepts.
    public static func connect(to path: String) -> Int32? {
        var info = stat()
        guard fits(path), stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let size = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: size) { strlcpy($0, path, size) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Writes all of `data`; false when the other side went away.
    public static func send(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var sent = 0
            while sent < buffer.count {
                let written = Darwin.send(descriptor, base + sent, buffer.count - sent, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                sent += written
            }
            return true
        }
    }

    /// Reads until the other side closes the connection, or until more than `limit` bytes arrived.
    public static func readToEnd(_ descriptor: Int32, limit: Int) -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= limit {
            let read = recv(descriptor, &buffer, buffer.count, 0)
            if read < 0 {
                if errno == EINTR { continue }
                break
            }
            if read == 0 { break }
            response.append(contentsOf: buffer[..<read])
        }
        return response
    }
}

/// The application's side of a `UnixSocket`: it listens at `path` and hands each request, once its sender stopped
/// writing, to `onRequest` with the connection, which answers it or lets it go. One process serves a path: a lock beside
/// the socket keeps a second copy of the application from replacing it, and a process removes only the socket it made.
@MainActor
public final class UnixSocketListener {
    public let path: String
    /// The largest request read; a longer one closes its connection.
    public let requestLimit: Int
    private let onRequest: @MainActor (Data, NWConnection) -> Void
    private let log: Logger
    private var listener: NWListener?
    /// The lock that makes this process the one serving the path, and the socket file it made, by device and inode.
    private var lock: Int32 = -1
    private var socket: [Int]?

    /// - category: names the socket in the application's log.
    public init(path: String, requestLimit: Int, category: String, onRequest: @escaping @MainActor (Data, NWConnection) -> Void) {
        self.path = path
        self.requestLimit = requestLimit
        self.onRequest = onRequest
        log = Logger(subsystem: "app.agenthud", category: category)
    }

    public var isListening: Bool { listener != nil }

    /// Starts listening; false when the path does not fit a socket address, another process serves it or the socket
    /// cannot be made.
    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        let path = path
        guard UnixSocket.fits(path) else {
            log.error("Socket path is too long for a unix socket: \(path, privacy: .public)")
            return false
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Another copy of the app opened beside this one, which shares its data directory, leaves the socket to the one
        // that serves it rather than replacing it; the lock goes with the process that holds it.
        let lock = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            log.info("Another instance serves \(path, privacy: .public)")
            return false
        }
        unlink(path)
        // The socket must never be readable by anyone else, not even for the moment between bind and chmod.
        let previous = umask(0o077)
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else {
            umask(previous)
            close(lock)
            log.error("Could not listen on \(path, privacy: .public)")
            return false
        }
        self.lock = lock
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    umask(previous)
                    chmod(path, 0o700)
                    self?.socket = Self.identity(path)
                case .failed:
                    umask(previous)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                self?.receive(connection, accumulated: Data())
            }
        }
        listener.start(queue: .main)
        return true
    }

    /// Stops listening. Only the socket this process made is removed.
    public func stop() {
        listener?.cancel()
        listener = nil
        if let socket, Self.identity(path) == socket { unlink(path) }
        socket = nil
        if lock >= 0 { close(lock) }
        lock = -1
    }

    private static func identity(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino)]
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                var data = accumulated
                if let content { data.append(content) }
                guard let self, data.count <= self.requestLimit else { return connection.cancel() }
                if isComplete || error != nil {
                    self.onRequest(data, connection)
                } else {
                    self.receive(connection, accumulated: data)
                }
            }
        }
    }
}
