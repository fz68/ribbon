import Foundation

/// Finds the external command line tools the app drives.
///
/// The two Homebrew prefixes come first, because a Homebrew install is the
/// supported setup and its binary is the one the user expects to be driven.
/// `$PATH` is only consulted when the caller asks for it.
enum ToolLocator {
    /// The Homebrew prefixes that are searched before `$PATH`.
    private static let homebrewPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The absolute path of `name`, or nil when it is not installed.
    ///
    /// - Parameter searchPATH: also search `$PATH` after the two Homebrew prefixes.
    /// - Parameter prefixes: the directories searched first, in order.
    /// - Parameter environment: the environment `$PATH` is read from.
    static func find(_ name: String, searchPATH: Bool,
                     prefixes: [String] = homebrewPrefixes,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for prefix in prefixes {
            let candidate = "\(prefix)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        guard searchPATH else { return nil }
        let searchPath = environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
