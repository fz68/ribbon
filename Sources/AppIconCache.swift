import Cocoa

/// Caches running-application icons by the app's localized name.
///
/// A chip rebuild used to scan `NSWorkspace.shared.runningApplications` once per
/// chip and once per icon, so a refresh cost a linear scan of every running app
/// for every app shown. An app's icon only changes when that app launches or
/// terminates, so the whole cache is dropped on exactly those two notifications
/// and a lookup normally costs one dictionary hit.
///
/// Main thread only: the lookups, the cache writes and the observer callbacks
/// all run there, so no locking is needed.
///
/// `generation` increments on every wholesale clear. It lets chip views detect
/// that cached icon images were invalidated even when their app list did not
/// change.
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private(set) static var generation = 0
    private static var launchObserver: NSObjectProtocol?
    private static var terminateObserver: NSObjectProtocol?

    /// The icon of the running app with this localized name, or nil when no app
    /// currently matches. Misses are not cached, so an app that launches later
    /// is found on the next call instead of being stuck as a miss.
    static func icon(for appName: String) -> NSImage? {
        registerObserversIfNeeded()
        if let cached = cache[appName] {
            return cached
        }
        guard let image = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == appName })?.icon else {
            return nil
        }
        cache[appName] = image
        return image
    }

    /// Registers the launch and terminate observers on first use.
    ///
    /// `NSWorkspace.shared.notificationCenter` is the center that carries these
    /// notifications, not `NotificationCenter.default`. The tokens are kept in
    /// static properties to make the registrations explicit; they are never
    /// removed because the cache lives as long as the app does.
    private static func registerObserversIfNeeded() {
        guard launchObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            cache.removeAll()
            generation += 1
        }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            cache.removeAll()
            generation += 1
        }
    }
}
