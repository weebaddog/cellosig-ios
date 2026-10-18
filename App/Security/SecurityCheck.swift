import Darwin
import Foundation
import MachO

/// Signs that this iPhone's own protections were broken (jailbreak, code
/// injected into cellosig, a debugger attached, the app sandbox not holding).
///
/// Honest limits: no app can detect a well-made spyware implant such as
/// Pegasus — it compromises iOS itself, then hides from apps. A clean result
/// here does NOT prove the phone is safe; a finding means it almost certainly
/// isn't. The real defences are iOS updates, Apple's Lockdown Mode, regular
/// restarts, and a scan with Amnesty International's Mobile Verification Toolkit.
enum SecurityCheck {
    struct Finding: Identifiable, Hashable {
        var id: String { what }
        var what: String
    }

    /// What the live check (SecurityMonitor) found most recently.
    @MainActor static var findings: [Finding] { SecurityMonitor.shared.findings }

    @MainActor static var compromised: Bool { !findings.isEmpty }

    /// A store copy that was decrypted and re-packaged (a cracked copy): it refuses to open.
    static let repackaged: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return fromAppleStore && !mainBinaryEncrypted()
        #endif
    }()

    /// Apple's Lockdown Mode (Settings → Privacy & Security). Read from a system
    /// setting apps can see; nil if this iOS doesn't say.
    static var appleLockdownMode: Bool? {
        UserDefaults.standard.object(forKey: "LDMGlobalEnabled") as? Bool
    }

    /// One full check (cheap: a few file checks, the loaded-code list, one local port probe).
    static func scan() -> [Finding] {
        var out: [Finding] = []
        #if targetEnvironment(simulator)
        return out
        #else
        // 1. Jailbreak tools on disk (an app can't normally even see these paths).
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
                     "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/lib/TweakInject", "/usr/sbin/sshd",
                     "/bin/bash", "/etc/apt", "/private/var/lib/apt", "/var/jb", "/private/preboot/jb",
                     "/usr/lib/libjailbreak.dylib", "/var/binpack"]
        for p in paths where access(p, F_OK) == 0 {
            out.append(Finding(what: "Jailbreak files are present (\(p))"))
            break
        }

        // 2. The sandbox: an app must not be able to write outside its own container.
        let probe = "/private/cellosig-sandbox-\(UUID().uuidString)"
        if (try? "x".write(toFile: probe, atomically: false, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            out.append(Finding(what: "The app sandbox isn't holding (cellosig could write outside its own storage)"))
        }

        // 3. Code injected into cellosig (hooking / instrumentation frameworks).
        // (Only names no part of iOS uses, so this never cries wolf on a normal phone.)
        let suspicious = ["frida", "cynject", "mobilesubstrate", "substrateloader", "libsubstitute", "libhooker",
                          "tweakinject", "sslkillswitch", "ellekit", "cycript"]
        for i in 0..<_dyld_image_count() {
            guard let c = _dyld_get_image_name(i) else { continue }
            let name = String(cString: c).lowercased()
            if let hit = suspicious.first(where: { name.contains($0) }) {
                out.append(Finding(what: "Foreign code was loaded into cellosig (\(hit))"))
                break
            }
        }
        if getenv("DYLD_INSERT_LIBRARIES") != nil {
            out.append(Finding(what: "Something asked iOS to inject code into cellosig (DYLD_INSERT_LIBRARIES)"))
        }

        // 4. A debugger attached to cellosig (it could read everything in memory).
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, (info.kp_proc.p_flag & P_TRACED) != 0 {
            out.append(Finding(what: "A debugger is attached to cellosig"))
        }

        // 5. A Frida instrumentation server on this phone (its default port).
        if localPortOpen(27042) {
            out.append(Finding(what: "A Frida instrumentation server is running on this iPhone"))
        }

        // 6. A copy from the App Store / TestFlight is encrypted by Apple. Cracked copies
        // are made by decrypting it and re-packaging: then the encryption is gone.
        if fromAppleStore && !mainBinaryEncrypted() {
            out.append(Finding(what: "This copy of cellosig was decrypted and re-packaged (not the one Apple delivered)"))
        }
        return out
        #endif
    }
}

/// The security check, running live: again every 15 s while cellosig is on
/// screen and each time you come back to it. Something new (a debugger
/// attaching, Frida starting, a jailbreak tool appearing) raises an alert
/// right away instead of waiting for you to look in Settings.
@MainActor
final class SecurityMonitor: ObservableObject {
    static let shared = SecurityMonitor()

    @Published private(set) var findings: [SecurityCheck.Finding] = SecurityCheck.scan()
    /// Findings that appeared since the last look, to alert about (nil = nothing new).
    @Published var alert: [SecurityCheck.Finding]?
    @Published private(set) var lastChecked = Date()

    private var timer: Timer?
    private var scanning = false

    /// cellosig is on screen: check now, then every 15 s.
    func resume() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in SecurityMonitor.shared.refresh() }
        }
    }

    /// Off screen: nobody to warn, so no checking.
    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let now = SecurityCheck.scan()
            await MainActor.run {
                let monitor = SecurityMonitor.shared
                monitor.scanning = false
                monitor.lastChecked = Date()
                let new = now.filter { !monitor.findings.contains($0) }
                if !new.isEmpty { monitor.alert = new }
                if now != monitor.findings { monitor.findings = now }
            }
        }
    }
}

extension SecurityCheck {
    /// Installed by the App Store or TestFlight (they leave a receipt; sideloaded copies don't).
    private static var fromAppleStore: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "CellosigKeepAlive") == nil,
              let r = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: r.path)
    }

    /// The app's own executable still carries Apple's FairPlay encryption (cryptid != 0).
    private static func mainBinaryEncrypted() -> Bool {
        guard let header = _dyld_get_image_header(0) else { return true }
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == LC_ENCRYPTION_INFO_64 {
                return cmd.assumingMemoryBound(to: encryption_info_command_64.self).pointee.cryptid != 0
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        return true   // no encryption section to judge by: don't cry wolf
    }

    /// Something is listening on 127.0.0.1:`port`.
    private static func localPortOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        // Non-blocking connect with a short wait, so a launch is never held up.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 100) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}
