import Foundation
import StrayCore

// StrayHelper: the root daemon behind "Clean" on an orphaned /Library/LaunchDaemons
// entry. launchd starts it on demand from the plist in the app bundle
// (Contents/Library/LaunchDaemons) once the user approves it in Login Items.
//
// It does one thing and trusts nothing. Only a Stray build signed by our team may
// connect (the listener's code-signing requirement), and every path is re-validated by
// `OrphanDaemonPolicy` regardless of who sent it.

final class HelperService: NSObject, StrayHelperProtocol {
    func removeOrphanDaemon(atPath path: String, reply: @escaping (String?) -> Void) {
        do {
            let label = try OrphanDaemonPolicy.validate(path: path)
            bootout(label)
            try OrphanDaemonPolicy.quarantine(path)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    /// Unloads the job if it is loaded. Failure is expected and ignored: an orphan whose
    /// program is gone has usually already failed to load.
    private func bootout(_ label: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "system/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: StrayHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: Helper.machServiceName)
// Checked by the system before `shouldAcceptNewConnection` runs; a connection from
// anything else never reaches the delegate.
listener.setConnectionCodeSigningRequirement(Helper.clientRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
