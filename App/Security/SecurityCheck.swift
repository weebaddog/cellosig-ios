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

    /// Run once per launch (cheap: a few file checks).
    static let findings: [Finding] = run()

    static var compromised: Bool { !findings.isEmpty }

    /// Apple's Lockdown Mode (Settings → Privacy & Security). Read from a system
    /// setting apps can see; nil if this iOS doesn't say.
    static var appleLockdownMode: Bool? {
        UserDefaults.standard.object(forKey: "LDMGlobalEnabled") as? Bool
    }

    private static func run() -> [Finding] {
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
        return out
        #endif
    }
}
