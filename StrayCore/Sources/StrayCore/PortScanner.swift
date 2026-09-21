import Foundation
import Darwin

/// Which TCP ports each process is listening on, read straight from libproc.
///
/// This is the same walk `lsof -iTCP -sTCP:LISTEN` does — every open file descriptor of
/// the process, keeping the sockets, keeping the TCP ones, keeping those in LISTEN — and
/// it is done in-process rather than by shelling out so a port list costs no subprocess
/// and cannot be blocked by a missing or sandboxed `lsof`.
///
/// It reads only PIDs it is handed, which in production are the ones `ProcessScanner`
/// already gathered for the same pass: every own-user process. Descriptors of other
/// users' processes are unreadable without root and simply report nothing.
enum PortScanner {

    /// Listening TCP ports per PID. PIDs with no listening socket are absent rather than
    /// mapped to an empty array, so a caller can treat presence as "this is a server".
    static func listeningPorts(for pids: [pid_t]) -> [pid_t: [UInt16]] {
        var result: [pid_t: [UInt16]] = [:]
        for pid in pids {
            let ports = listeningPorts(ofPID: pid)
            if !ports.isEmpty { result[pid] = ports }
        }
        return result
    }

    private static func listeningPorts(ofPID pid: pid_t) -> [UInt16] {
        // Two-call pattern: ask for the size, then fill. A process can open descriptors
        // between the calls, so the second result is re-derived from its own return value
        // and never assumed to have filled the buffer.
        let sizeHint = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizeHint > 0 else { return [] }

        let capacity = Int(sizeHint) / MemoryLayout<proc_fdinfo>.stride
        guard capacity > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)

        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, sizeHint)
        guard filled > 0 else { return [] }
        let count = min(Int(filled) / MemoryLayout<proc_fdinfo>.stride, capacity)

        // A server bound to both 0.0.0.0 and [::] holds two listening sockets on one
        // port; a Set makes that one port, because it is one thing to kill.
        var ports: Set<UInt16> = []
        for i in 0..<count where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            if let port = listeningPort(pid: pid, fd: fds[i].proc_fd) { ports.insert(port) }
        }
        return Array(ports)
    }

    /// The local port of `fd`, or nil if it is not a TCP socket in LISTEN state. A
    /// descriptor that has been bound but never listened on is a claimed port, not a
    /// server, and is deliberately excluded.
    private static func listeningPort(pid: pid_t, fd: Int32) -> UInt16? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        guard info.psi.soi_kind == SOCKINFO_TCP else { return nil }

        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }

        // `insi_lport` is an `int` holding the port in network byte order, which is what
        // `ntohs` in the C equivalent undoes. Port 0 means the kernel never assigned one.
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        return port == 0 ? nil : port
    }
}
