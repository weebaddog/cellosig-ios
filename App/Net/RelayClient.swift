import CellosigCore
import Foundation

/// One WebSocket to the relay, reconnecting with exponential backoff + jitter.
/// Frames are delivered on the main actor, in order.
@MainActor
final class RelayClient {
    private(set) var url: URL
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var attempt = 0
    private var closed = true
    private var generation = 0
    private var pingTimer: Timer?

    var onFrame: ((InboundFrame) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    private(set) var isConnected = false

    init(url: URL) {
        self.url = url
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    func connect() {
        closed = false
        open()
    }

    func close() {
        closed = true
        generation += 1
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    /// Network came back / app returned to the foreground: try now instead of waiting out the backoff.
    func reconnectNow() {
        guard !closed, !isConnected else { return }
        attempt = 0
        open()
    }

    func move(to newURL: URL) {
        url = newURL
        if !closed { task?.cancel(with: .goingAway, reason: nil); open() }
    }

    @discardableResult
    func send<T: Encodable>(_ frame: T) -> Bool {
        guard isConnected, let task else { return false }
        task.send(.string(Wire.json(frame))) { _ in }
        return true
    }

    private func open() {
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 2 * 1024 * 1024
        task = t
        t.resume()
        // URLSession reports "open" only implicitly; a ping that comes back means we're through.
        t.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if error == nil { self.attempt = 0; self.setConnected(true); self.startPings(gen) } else { self.retry(gen) }
            }
        }
        receive(t, gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg, let f = InboundFrame.parse(s) { self.onFrame?(f) }
                    self.receive(t, gen)
                case .failure:
                    self.retry(gen)
                }
            }
        }
    }

    private func startPings(_ gen: Int) {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.task?.sendPing { error in
                    if error != nil { Task { @MainActor in if gen == self.generation { self.retry(gen) } } }
                }
            }
        }
    }

    private func retry(_ gen: Int) {
        guard gen == generation else { return }
        pingTimer?.invalidate()
        setConnected(false)
        guard !closed else { return }
        generation += 1
        let next = generation
        attempt += 1
        let base = min(30.0, pow(2.0, Double(min(attempt, 5))))
        let delay = base * Double.random(in: 0.5...1.0)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if next == self.generation, !self.closed { self.open() }
        }
    }

    private func setConnected(_ up: Bool) {
        guard up != isConnected else { return }
        isConnected = up
        if up { onConnected?() } else { onDisconnected?() }
    }
}

/// Short-lived connection for sign-up (before there's an account).
enum PhoneVerification {
    enum Outcome { case ok(token: String?), failed(String) }

    struct Start: Encodable { var type = "verifyStart"; var phone: String }
    struct Check: Encodable { var type = "verifyCheck"; var phone: String; var code: String }

    static func requestCode(relay: URL, phone: String) async -> Outcome {
        await exchange(relay, expect: "verifyStarted", frame: Start(phone: phone))
    }

    static func submitCode(relay: URL, phone: String, code: String) async -> Outcome {
        await exchange(relay, expect: "verified", frame: Check(phone: phone, code: code))
    }

    private static func exchange<T: Encodable>(_ relay: URL, expect: String, frame: T) async -> Outcome {
        let task = URLSession.shared.webSocketTask(with: relay)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        do {
            try await task.send(.string(Wire.json(frame)))
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    while true {
                        if case .string(let s) = try await task.receive(), let f = InboundFrame.parse(s) {
                            if f.type == expect { return .ok(token: f.token) }
                            if f.type == "error" { return .failed(f.reason ?? "error") }
                        }
                    }
                }
                group.addTask { try await Task.sleep(nanoseconds: 20_000_000_000); return .failed("unreachable") }
                let first = try await group.next() ?? .failed("unreachable")
                group.cancelAll()
                return first
            }
        } catch {
            return .failed("unreachable")
        }
    }
}

/// Encrypted attachment blobs on the relay's HTTP side (ws -> http, wss -> https).
struct BlobClient {
    let base: URL
    let user: String
    let token: String
    static let blobId = #"^[A-Za-z0-9_-]{43}$"#

    init(relay: URL, user: String, token: String) {
        var c = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme?.lowercased() == "wss") ? "https" : "http"
        c.path = ""
        base = c.url!
        self.user = user
        self.token = token
    }

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.setValue(user, forHTTPHeaderField: "x-cellosig-user")
        r.setValue(token, forHTTPHeaderField: "x-cellosig-token")
        r.timeoutInterval = 120
        return r
    }

    func upload(file: URL) async throws -> String {
        var r = request("blob")
        r.httpMethod = "PUT"
        r.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        let (data, resp) = try await URLSession.shared.upload(for: r, fromFile: file)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? String
        else { throw URLError(.badServerResponse) }
        return id
    }

    /// Download into `dest`, refusing more than `maxBytes` (a sender may lie about the size).
    func download(_ id: String, to dest: URL, maxBytes: Int64) async throws {
        guard id.range(of: Self.blobId, options: .regularExpression) != nil else { throw URLError(.badURL) }
        let (tmp, resp) = try await URLSession.shared.download(for: request("blob/\(id)"))
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? .max
        guard size <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
