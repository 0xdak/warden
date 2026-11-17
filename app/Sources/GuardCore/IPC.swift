import Foundation

// Newline-delimited JSON over a Unix domain socket (mode 0600, same-user peers only).
// hook → app: {"type":"ask", …}   app → hook: {"decision":"allow|block","scope":"once|project|always"}
// hook → app: {"type":"ping"}     app → hook: {"decision":"pong"}

public struct AskRequest: Codable, Sendable {
    public var type = "ask"
    public var id: String = UUID().uuidString
    public var agent: Agent
    public var kind: ActionKind
    public var tool: String
    /// Exact target, used for remembered decisions. Never written to disk by the app.
    public var target: String
    /// Redacted target, used for display.
    public var summary: String
    public var cwd: String
    public var project: String
    public var match: RuleMatch
    public var otherMatches: [RuleMatch] = []
    public var timeout: Int
    public var unsafe: [String] = []
    public var createdAt = Date()

    public init(agent: Agent, kind: ActionKind, tool: String, target: String, summary: String, cwd: String, project: String,
                match: RuleMatch, otherMatches: [RuleMatch], timeout: Int, unsafe: [String]) {
        self.agent = agent; self.kind = kind; self.tool = tool; self.target = target; self.summary = summary
        self.cwd = cwd; self.project = project; self.match = match; self.otherMatches = otherMatches
        self.timeout = timeout; self.unsafe = unsafe
    }
}

public struct AskReply: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case once, project, always }
    public var decision: String   // allow | block | pong
    public var scope: Scope = .once
    public var timedOut: Bool? = nil
    public init(decision: String, scope: Scope = .once, timedOut: Bool? = nil) {
        self.decision = decision; self.scope = scope; self.timedOut = timedOut
    }
    public var allows: Bool { decision == "allow" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decision = try c.decode(String.self, forKey: .decision)
        scope = (try? c.decode(Scope.self, forKey: .scope)) ?? .once
        timedOut = try? c.decode(Bool.self, forKey: .timedOut)
    }
}

enum SocketAddress {
    static func make(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = UInt8(bitPattern: b) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}

enum SocketIO {
    static func noSigpipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setRecvTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { buf -> Bool in
            while sent < buf.count {
                let n = write(fd, buf.baseAddress! + sent, buf.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Reads until newline, EOF, timeout or `max` bytes.
    static func readLine(_ fd: Int32, max: Int = 1 << 20) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < max {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if let nl = out.firstIndex(of: 0x0A) { return out[out.startIndex..<nl] }
        }
        return out.isEmpty ? nil : out
    }
}

/// Hook side.
public enum GuardClient {
    public enum Failure: Error { case notRunning, timedOut, badReply }

    /// Sends `req` and waits up to `wait` seconds for the user's answer.
    public static func ask(_ req: AskRequest, socketPath: String = Paths.socket, wait: Double) -> Result<AskReply, Failure> {
        guard let fd = connectSocket(socketPath) else { return .failure(.notRunning) }
        defer { close(fd) }
        guard var data = try? JSONFile.lineEncoder.encode(req) else { return .failure(.badReply) }
        data.append(0x0A)
        guard SocketIO.writeAll(fd, data) else { return .failure(.notRunning) }
        SocketIO.setRecvTimeout(fd, seconds: wait)
        guard let line = SocketIO.readLine(fd) else { return .failure(.timedOut) }
        guard let reply = try? JSONFile.decoder.decode(AskReply.self, from: line) else { return .failure(.badReply) }
        return .success(reply)
    }

    public static func ping(socketPath: String = Paths.socket) -> Bool {
        guard let fd = connectSocket(socketPath) else { return false }
        defer { close(fd) }
        guard SocketIO.writeAll(fd, Data("{\"type\":\"ping\"}\n".utf8)) else { return false }
        SocketIO.setRecvTimeout(fd, seconds: 1)
        guard let line = SocketIO.readLine(fd), let r = try? JSONFile.decoder.decode(AskReply.self, from: line) else { return false }
        return r.decision == "pong"
    }

    /// Sends a control message (terminal approvals) and returns the JSON reply.
    public static func control(_ msg: [String: Any], socketPath: String = Paths.socket) -> [String: Any]? {
        guard let fd = connectSocket(socketPath), var d = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
        defer { close(fd) }
        d.append(0x0A)
        guard SocketIO.writeAll(fd, d) else { return nil }
        SocketIO.setRecvTimeout(fd, seconds: 3)
        guard let line = SocketIO.readLine(fd) else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func connectSocket(_ path: String) -> Int32? {
        guard var addr = SocketAddress.make(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        SocketIO.noSigpipe(fd)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }
}

/// App side. `handler` is called on a background thread; call `respond` exactly once (from any thread).
public final class GuardServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AskRequest, _ respond: @escaping @Sendable (AskReply) -> Void) -> Void

    /// Terminal approvals: {"type":"list"} / {"type":"resolve","id":…,"decision":…,"scope":…} → JSON object reply.
    public typealias ControlHandler = @Sendable ([String: Any]) -> [String: Any]

    private let path: String
    private let handler: Handler
    public var control: ControlHandler?
    private var listenFD: Int32 = -1
    private var running = false

    public init(path: String = Paths.socket, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        Paths.ensureSupport()
        // Replace a stale socket left by a crash (only if it is a socket).
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
        guard var addr = SocketAddress.make(path) else { throw NSError(domain: "GuardServer", code: 1) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "GuardServer", code: 2) }
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { close(fd); throw NSError(domain: "GuardServer", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]) }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { close(fd); throw NSError(domain: "GuardServer", code: 4) }
        listenFD = fd
        running = true
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "\(Brand.identifierPrefix).socket"
        t.start()
    }

    public func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let c = accept(listenFD, nil, nil)
            if c < 0 { if !running { return }; continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }
            SocketIO.noSigpipe(c)
            let t = Thread { [handler, control] in GuardServer.serve(c, handler: handler, control: control) }
            t.start()
        }
    }

    private static func serve(_ fd: Int32, handler: Handler, control: ControlHandler?) {
        SocketIO.setRecvTimeout(fd, seconds: 5)
        guard let line = SocketIO.readLine(fd) else { close(fd); return }
        let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        if obj?["type"] as? String == "ping" {
            _ = SocketIO.writeAll(fd, Data("{\"decision\":\"pong\"}\n".utf8))
            close(fd); return
        }
        if let o = obj, let type = o["type"] as? String, type == "list" || type == "resolve" {
            let reply = control?(o) ?? ["error": "unsupported"]
            if var d = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) {
                d.append(0x0A); _ = SocketIO.writeAll(fd, d)
            }
            close(fd); return
        }
        guard let req = try? JSONFile.decoder.decode(AskRequest.self, from: line) else { close(fd); return }
        let done = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        handler(req) { reply in
            box.set(reply)
            done.signal()
        }
        _ = done.wait(timeout: .now() + .seconds(req.timeout + 30))
        if let r = box.get(), var data = try? JSONFile.lineEncoder.encode(r) {
            data.append(0x0A)
            _ = SocketIO.writeAll(fd, data)
        }
        close(fd)
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AskReply?
        func set(_ v: AskReply) { lock.lock(); if value == nil { value = v }; lock.unlock() }
        func get() -> AskReply? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
