import CryptoKit
import Foundation

/// Encrypted WebSocket to Cindy on the PC, the same way her phone app connects. At home the PC's self-signed
/// certificate is pinned (SHA-256 from the pairing QR); away from home it goes through the Cloudflare tunnel
/// with normal certificate checks. Either way everything inside is end-to-end sealed (CindyE2E).
/// The hello says which app this is and what Cindy can do in it. Everything runs on the main queue.
final class CindyLink: NSObject, URLSessionWebSocketDelegate {
    enum Status { case connecting, connected(String), offline(String), revoked }

    var onStatus: (Status) -> Void = { _ in }
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onHosts: (CindyPairing) -> Void = { _ in }

    private var pairing: CindyPairing
    private let app: [String: Any]
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var handshake: CindyE2E.Handshake?
    private var channel: CindyE2E?
    private var pin: String?  // nil = the tunnel (normal TLS checks)
    private var host = ""
    private var hostIndex = 0
    private var failures = 0
    private var running = false
    private var generation = 0
    private var ping: Timer?
    // The PC numbers what it sends; after a reconnect it replays anything past lastSeq (same epoch only).
    private var epoch = ""
    private var lastSeq = 0

    init(pairing: CindyPairing, app: [String: Any]) {
        self.pairing = pairing
        self.app = app
    }

    /// Home addresses first, then the tunnel.
    private var targets: [String] { pairing.hosts + (pairing.remote.isEmpty ? [] : [pairing.remote]) }

    private func startAt(awayFromHome: Bool) {
        hostIndex = awayFromHome && !pairing.remote.isEmpty ? pairing.hosts.count : 0
    }

    func start(awayFromHome: Bool) {
        running = true
        startAt(awayFromHome: awayFromHome)
        open()
    }

    func stop() {
        running = false
        generation += 1
        tearDown()
    }

    /// The network changed: don't wait for the backoff, try again now.
    func reconnectNow(awayFromHome: Bool) {
        guard running else { return }
        failures = 0
        startAt(awayFromHome: awayFromHome)
        open()
    }

    @discardableResult
    func send(_ msg: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return false }
        return seal(0, data)
    }

    /// Recorded speech (16 kHz mono 16-bit); flags byte 0 = no wake word needed.
    @discardableResult
    func sendAudio(_ pcm: Data) -> Bool { seal(1, Data([0]) + pcm) }

    private func seal(_ kind: UInt8, _ data: Data) -> Bool {
        guard let task, let channel, let frame = try? channel.seal(kind, data) else { return false }
        task.send(.data(frame)) { _ in }
        return true
    }

    private func tearDown() {
        ping?.invalidate()
        ping = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        channel = nil
        handshake = nil
    }

    private func open() {
        tearDown()
        generation += 1
        let gen = generation
        let all = targets
        guard !all.isEmpty else { return }
        host = all[hostIndex % all.count]
        let viaTunnel = host == pairing.remote
        pin = viaTunnel ? nil : pairing.fingerprint
        onStatus(.connecting)
        let url = URL(string: viaTunnel ? "wss://\(host)/" : "wss://\(host):\(pairing.port)/")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120  // idle limit; pings every 20 s keep it alive
        let s = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        let t = s.webSocketTask(with: url)
        t.maximumMessageSize = 8 * 1024 * 1024
        session = s
        task = t
        handshake = CindyE2E.Handshake(token: pairing.token)
        t.resume()
        receive(t, gen)
        // a home address that isn't there would take a long time to time out by itself
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, gen == self.generation, self.channel == nil else { return }
            self.fail(gen)
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure:
                    self.fail(gen)
                case .success(let message):
                    switch message {
                    case .string(let text): self.beforeHandshake(text, gen)
                    case .data(let data): self.sealed(data, gen)
                    @unknown default: break
                    }
                    if gen == self.generation { self.receive(t, gen) }
                }
            }
        }
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task, let handshake else { return }
        let hello: [String: Any] = ["type": "hello2", "id": handshake.id, "pub": handshake.pub]
        if let d = try? JSONSerialization.data(withJSONObject: hello), let s = String(data: d, encoding: .utf8) {
            webSocketTask.send(.string(s)) { _ in }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        if closeCode.rawValue == 4001 { notPaired() } else { fail(generation) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        fail(generation)
    }

    /// The PC's certificate: at home exactly the one whose SHA-256 came in the QR code; via the tunnel, normal checks.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, session === self.session, let pin else {
            return completionHandler(.performDefaultHandling, nil)
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard let leaf = chain.first else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        let got = CindyE2E.hex(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        if got == pin { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    /// Before the handshake: only the PC's key, or "not paired". After it, plain text is ignored.
    private func beforeHandshake(_ text: String, _ gen: Int) {
        guard channel == nil, let msg = Self.json(Data(text.utf8)) else { return }
        switch msg["type"] as? String {
        case "hello2":
            guard let handshake, let pub = msg["pub"] as? String, let e2e = try? handshake.finish(pcPub: pub) else {
                return fail(gen)
            }
            channel = e2e
            send(["type": "hello", "epoch": epoch, "last": lastSeq, "app": app])
            ping = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { error in
                    if error != nil { DispatchQueue.main.async { if gen == self?.generation { self?.fail(gen) } } }
                }
            }
        case "unpaired":
            notPaired()
        default:
            break
        }
    }

    private func sealed(_ frame: Data, _ gen: Int) {
        guard let channel else { return }
        guard let opened = try? channel.open(frame) else { return fail(gen) }  // not from the paired PC
        guard opened.0 == 0, let msg = Self.json(opened.1) else { return }
        if let seq = msg["s"] as? Int, seq > 0 {  // numbered by the PC: skip anything already seen before a reconnect
            if seq <= lastSeq { return }
            lastSeq = seq
        }
        guard msg["type"] as? String == "ready" else { return onMessage(msg) }
        failures = 0
        let pcEpoch = msg["epoch"] as? String ?? ""
        if pcEpoch != epoch {  // the PC app restarted: its numbering starts over
            epoch = pcEpoch
            lastSeq = 0
        }
        let hosts = (msg["hosts"] as? [String] ?? []).filter { $0.range(of: #"^[0-9.]{7,15}$"#, options: .regularExpression) != nil }
        let remote = CindyPairing.cleanRemote(msg["remote"] as? String)
        let newHosts = !hosts.isEmpty && Set(hosts) != Set(pairing.hosts)
        if newHosts || remote != pairing.remote {
            if pin == nil { pairing.hosts = hosts.isEmpty ? pairing.hosts : hosts }
            else if newHosts { pairing.hosts = ([host] + hosts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
            pairing.remote = remote
            hostIndex = max(targets.firstIndex(of: host) ?? 0, 0)
            onHosts(pairing)
        }
        onStatus(.connected(msg["pc"] as? String ?? pairing.pcName))
    }

    /// Only believed over the pinned home connection (through the tunnel it could be Cloudflare talking).
    private func notPaired() {
        guard pin != nil, channel == nil else { return }
        running = false
        generation += 1
        tearDown()
        onStatus(.revoked)
    }

    private func fail(_ gen: Int) {
        guard running, gen == generation else { return }
        generation += 1
        tearDown()
        failures += 1
        hostIndex += 1
        onStatus(.offline("Can't reach Cindy on \(pairing.pcName). Is she running on the PC?"))
        // try every known address quickly, then back off up to 30 s
        let delay = failures < targets.count ? 0.3 : min(30, Double(1 << min(failures, 5)))
        let next = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, next == self.generation else { return }
            self.open()
        }
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
