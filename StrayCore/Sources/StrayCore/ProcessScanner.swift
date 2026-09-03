import Foundation
import Darwin

struct ScannedProcess {
    let pid: pid_t
    let ppid: pid_t
    let path: String
    let arguments: String   // full command line (best-effort)
    let startedAt: Date
    let uid: uid_t

    var isOrphan: Bool { ppid == 1 }
    var binaryName: String { (path as NSString).lastPathComponent }
}

enum ProcessScanner {

    /// Lists every process owned by the current user with PPID, path and start time.
    static func scan() -> [ScannedProcess] {
        listAllPIDs().compactMap { inspect(pid: $0) }
            .filter { $0.uid == getuid() } // v1: only our own processes
    }

    private static func listAllPIDs() -> [pid_t] {
        var size = proc_listallpids(nil, 0)
        guard size > 0 else { return [] }
        // headroom for processes spawned between the two calls
        var pids = [pid_t](repeating: 0, count: Int(size) * 2)
        size = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard size > 0 else { return [] }
        return Array(pids.prefix(Int(size))).filter { $0 > 0 }
    }

    private static func inspect(pid: pid_t) -> ScannedProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        // PROC_PIDPATHINFO_MAXSIZE is a <sys/proc_info.h> macro, not exposed to Swift
        var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = String(cString: pathBuf)
        guard !path.isEmpty else { return nil }

        return ScannedProcess(
            pid: pid,
            ppid: pid_t(info.pbi_ppid),
            path: path,
            arguments: commandLine(of: pid) ?? path,
            startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)),
            uid: info.pbi_uid
        )
    }

    /// Arguments via sysctl KERN_PROCARGS2 (fails silently for other users' processes).
    private static func commandLine(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32) | exec_path \0 ... \0 | argv[0] \0 argv[1] \0 ...
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var offset = MemoryLayout<Int32>.size
        // skip exec_path and its \0 padding
        while offset < size, buf[offset] != 0 { offset += 1 }
        while offset < size, buf[offset] == 0 { offset += 1 }

        var args: [String] = []
        var current: [UInt8] = []
        var found = 0
        while offset < size, found < argc {
            if buf[offset] == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll()
                found += 1
            } else {
                current.append(buf[offset])
            }
            offset += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    /// SIGTERM; if still alive after `grace` seconds, SIGKILL.
    @discardableResult
    static func terminate(pid: pid_t, grace: TimeInterval = 3) -> Bool {
        guard kill(pid, SIGTERM) == 0 else { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            // 0 = "does it exist?"; if it still does, escalate
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        return true
    }
}
