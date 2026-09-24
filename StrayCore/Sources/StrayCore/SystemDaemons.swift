import Foundation

/// The contract between Stray and `StrayHelper`, the root daemon that removes orphaned
/// entries from `/Library/LaunchDaemons`. Both sides link this file, so the service
/// name, the XPC protocol and the signing requirements cannot drift apart.
public enum Helper {
    public static let machServiceName = "com.stepan.Stray.Helper"
    /// The launchd plist inside the app bundle, at `Contents/Library/LaunchDaemons`.
    public static let plistName = "com.stepan.Stray.Helper.plist"
    public static let teamID = "97AYLS48JS"

    /// What the helper demands of anything connecting to it: the Stray app, signed by
    /// this team. Without it any local process could ask a root daemon to delete files.
    public static let clientRequirement =
        #"identifier "com.stepan.Stray" and anchor apple generic and certificate leaf[subject.OU] = "97AYLS48JS""#

    /// What the app demands of the helper it talks to, so it never hands paths to an
    /// impostor that registered the same Mach service name.
    public static let helperRequirement =
        #"identifier "com.stepan.Stray.Helper" and anchor apple generic and certificate leaf[subject.OU] = "97AYLS48JS""#

    /// Where removed plists go instead of being deleted, so a removal can be undone by
    /// moving the file back.
    public static let quarantineDirectory = "/Library/Application Support/Stray/RemovedDaemons"
}

/// The helper's only operation. `reply` carries nil on success, or a message fit to show
/// the user.
@objc public protocol StrayHelperProtocol {
    func removeOrphanDaemon(atPath path: String, reply: @escaping (String?) -> Void)
}

/// The checks the helper runs, as root, before touching anything. It trusts nothing the
/// app says: the path is re-validated from scratch and the plist must *still* point at a
/// program that does not exist. So even a compromised client can only get the helper to
/// remove daemons that are already broken, which is the whole feature.
///
/// Pure except for reading the one file, so it is testable against a temporary
/// directory standing in for `/Library/LaunchDaemons`.
public enum OrphanDaemonPolicy {
    public struct Rejection: LocalizedError, Equatable {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    public static let daemonsDirectory = "/Library/LaunchDaemons"

    /// Returns the plist's launchd label when `path` is safe to remove, or throws.
    ///
    /// `requireRootOwner` exists only so tests can run unprivileged; the helper always
    /// passes the default.
    public static func validate(
        path: String,
        daemonsDirectory: String = daemonsDirectory,
        requireRootOwner: Bool = true
    ) throws -> String {
        guard path.hasPrefix("/") else { throw Rejection(reason: "Not an absolute path: \(path)") }

        // Textual check first: the file must sit directly in the daemons directory, with
        // no `..` or extra components that standardizing would collapse.
        let url = URL(fileURLWithPath: path)
        guard url.standardized.path == path,
              url.deletingLastPathComponent().path == daemonsDirectory,
              url.pathExtension == "plist"
        else { throw Rejection(reason: "Only .plist files directly in \(daemonsDirectory) can be removed.") }

        // lstat, not stat: a symlink is refused rather than followed, so the helper can
        // never be pointed at a file outside the directory through a link inside it.
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Rejection(reason: "\(path) no longer exists.") }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Rejection(reason: "\(path) is not a regular file.")
        }
        if requireRootOwner, info.st_uid != 0 {
            throw Rejection(reason: "\(path) is not owned by root.")
        }

        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { throw Rejection(reason: "\(path) is not a readable property list.") }

        guard let program = LaunchdScanner.program(in: plist), program.hasPrefix("/") else {
            throw Rejection(reason: "\(path) does not name an absolute program path.")
        }
        guard !FileManager.default.fileExists(atPath: program) else {
            throw Rejection(reason: "\(program) exists, so this daemon is not orphaned.")
        }

        guard let label = plist["Label"] as? String, !label.isEmpty, !label.contains("/") else {
            throw Rejection(reason: "\(path) has no usable Label.")
        }
        return label
    }

    /// Moves `path` into `directory`, creating it if needed, under a timestamped name so
    /// removing a daemon twice never overwrites the first copy.
    @discardableResult
    public static func quarantine(
        _ path: String,
        into directory: String = Helper.quarantineDirectory,
        now: Date = Date()
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let stamp = Int(now.timeIntervalSince1970)
        let name = "\(stamp)-\((path as NSString).lastPathComponent)"
        let destination = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try fm.moveItem(at: URL(fileURLWithPath: path), to: destination)
        return destination
    }
}
