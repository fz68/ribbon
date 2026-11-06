import Foundation

/// One running opencode background service, as described by its registration
/// file.
///
/// The password is equivalent to a bearer token: it is kept in memory only and
/// deliberately left out of every textual form of this value, so no log line,
/// crash report or diagnostic dump can leak it.
struct ServiceEndpoint: Equatable {
    /// Base URL of the service, e.g. `http://127.0.0.1:49374`.
    let url: URL
    /// Basic-auth password; the user name is fixed to `opencode`.
    let password: String
    /// The opencode version that wrote the registration file.
    let version: String
    /// The service process id, so a restart can be recognised.
    let pid: Int32
}

extension ServiceEndpoint {
    /// The HTTP Basic header value every request must carry.
    ///
    /// Derived on demand from the in-memory password instead of being stored,
    /// so the encoded form (which is not a secret in any meaningful sense, but
    /// is still not worth keeping around) never outlives the request.
    var authorizationHeader: String {
        "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    }
}

extension ServiceEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted on purpose: the password must never reach a log.
    var description: String {
        "ServiceEndpoint(url: \(url.absoluteString), version: \(version), pid: \(pid))"
    }

    /// Delegates to `description`, so printing a debug view is equally safe.
    var debugDescription: String { description }
}

extension ServiceEndpoint: CustomReflectable {
    /// Mirrors the value with the password replaced.
    ///
    /// `description` alone is not enough: `Mirror(reflecting:)` (used by crash
    /// reporters, playgrounds and debug dumps) walks the stored properties
    /// directly and would otherwise print the secret.
    var customMirror: Mirror {
        Mirror(self,
               children: [
                   "url": url,
                   "password": "<redacted>",
                   "version": version,
                   "pid": pid,
               ],
               displayStyle: .struct)
    }
}
