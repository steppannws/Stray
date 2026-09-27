import Foundation
import ServiceManagement

/// The app's side of `StrayHelper`: registers the daemon on first use and sends it one
/// path at a time over XPC.
///
/// Registration is lazy on purpose. A root daemon is a lot to ask for, so it is only
/// requested the first time the user tries to clean a system daemon — never at launch,
/// and never for anyone who only uses the user-level features.
enum HelperClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var service: SMAppService { .daemon(plistName: Helper.plistName) }

    static func removeOrphanDaemon(atPath path: String) async throws {
        try ensureEnabled()
        try await call(path)
    }

    /// macOS requires the user to approve a new daemon in System Settings before it may
    /// run, so the first attempt registers it, opens that pane and stops; the user clicks
    /// Clean again once it is allowed.
    private static func ensureEnabled() throws {
        let approval = Failure(message:
            "Allow Stray in System Settings → General → Login Items, then click Clean again.")
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw approval
        case .notRegistered, .notFound:
            try service.register()
            guard service.status == .enabled else {
                SMAppService.openSystemSettingsLoginItems()
                throw approval
            }
        @unknown default:
            throw Failure(message: "The helper is in an unknown state (\(service.status.rawValue)).")
        }
    }

    private static func call(_ path: String) async throws {
        let connection = NSXPCConnection(machServiceName: Helper.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: StrayHelperProtocol.self)
        connection.setCodeSigningRequirement(Helper.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // XPC promises either the reply or the error handler, but a continuation
            // resumed twice is a crash, so make that promise impossible to break.
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: Failure(message:
                    "Could not reach the helper: \(error.localizedDescription)"))
            } as? StrayHelperProtocol
            guard let proxy else {
                once.resume(throwing: Failure(message: "The helper has an unexpected interface."))
                return
            }
            proxy.removeOrphanDaemon(atPath: path) { message in
                if let message {
                    once.resume(throwing: Failure(message: message))
                } else {
                    once.resume()
                }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(throwing error: Error? = nil) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
