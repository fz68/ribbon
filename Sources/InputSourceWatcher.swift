import Foundation
import Carbon

/// Watches the selected keyboard input source and reports every change.
///
/// The Carbon notification is the preferred signal, but it is not delivered on
/// every macOS release, so a one second poll runs next to it and takes over
/// when the notification stays silent. Both paths are cheap: they read two
/// properties of an object the system already keeps in memory and never spawn
/// a process.
final class InputSourceWatcher {
    /// Called on the main thread whenever the selected source changes.
    var onChange: ((_ id: String, _ name: String) -> Void)?

    private var lastID: String?
    private var pendingChange: InputSourceDescriptor?
    private var pollTimer: Timer?
    private var lastNotificationAt: Date?
    private var loggedNotificationDelivered = false
    private var loggedNotificationMissing = false
    private var isRunning = false
    /// Whether the Carbon observer currently holds a retain on this object.
    ///
    /// The context is registered with `passRetained`, so exactly one matching
    /// `release` is owed. This flag is the single record of that debt: it is
    /// only ever read or written on the main thread, the same thread `start()`
    /// and `stop()` run on.
    private var notificationRegistered = false

    /// Starts watching. Must be called on the main thread.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerNotification()
        lastID = InputSource.current?.id
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        log("ime watcher started notification=registered poll=1s")
    }

    /// Stops watching and removes the Carbon observer.
    ///
    /// Idempotent: only the first call tears anything down, so the observer's
    /// retain is released exactly once. There is no `deinit` counterpart on
    /// purpose - a registered watcher is retained by the notification centre
    /// context, so it cannot deinitialize while the registration is live; the
    /// only path out is this method, which unregisters before releasing.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        guard notificationRegistered else { return }
        notificationRegistered = false
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Remove first: the observer must not be able to deliver a callback that
        // unretains this object while the context is still registered.
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDistributedCenter(), context, nil, nil)
        // Last statement of the method: this drops the retain from
        // `registerNotification`, and nothing below may touch `self` afterwards.
        Unmanaged<InputSourceWatcher>.fromOpaque(context).release()
    }

    /// Registers the Carbon notification. It is the preferred signal but it is
    /// not delivered everywhere, so the poll stays in place as the fallback.
    private func registerNotification() {
        guard let name = kTISNotifySelectedKeyboardInputSourceChanged else {
            log("ime notification unavailable, poll only")
            return
        }
        // Retained so a callback that arrives while the owner is releasing this
        // object still has a live instance to unretain; `stop()` releases it.
        let context = Unmanaged.passRetained(self).toOpaque()
        notificationRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            context,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let watcher = Unmanaged<InputSourceWatcher>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    watcher.handleNotification()
                }
            },
            name,
            nil,
            .deliverImmediately
        )

        // The enabled set changes when an IME is installed or removed, which can
        // reassign the round-robin palette colours without the selection moving.
        if let enabled = kTISNotifyEnabledKeyboardInputSourcesChanged {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDistributedCenter(),
                context,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let watcher = Unmanaged<InputSourceWatcher>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async {
                        watcher.handleEnabledSourcesChanged()
                    }
                },
                enabled,
                nil,
                .deliverImmediately
            )
        }
    }

    /// The enabled set changes when an IME is installed or removed, which can
    /// reassign the round-robin palette colours without the selection moving.
    private func handleEnabledSourcesChanged() {
        // A callback can already be on its way to main when `stop()` runs.
        guard isRunning else { return }
        InputSource.invalidateBuiltInCache()
        guard let current = InputSource.current else { return }
        onChange?(current.id, current.name)
    }

    private func handleNotification() {
        guard isRunning else { return }
        lastNotificationAt = Date()
        if !loggedNotificationDelivered {
            loggedNotificationDelivered = true
            log("ime notification delivered")
        }
        checkForChange()
    }

    private func poll() {
        checkForChange()
    }

    /// Looks for a new source and reports it once the Carbon notification had
    /// its chance to arrive, so a delivered notification is not counted twice.
    private func checkForChange() {
        guard let current = InputSource.current else { return }
        guard current.id != lastID else { return }
        pendingChange = current
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.commitPendingChange()
        }
    }

    private func commitPendingChange() {
        guard isRunning else { return }
        guard let current = pendingChange else { return }
        pendingChange = nil
        guard current.id != lastID else { return }
        lastID = current.id
        if lastNotificationAt == nil, !loggedNotificationMissing {
            loggedNotificationMissing = true
            log("ime notification unusable, 1s poll in use")
            Log.status.error("ime notification unusable, 1s poll in use")
        }
        // The source list may have changed with the selection, so the built-in
        // configuration has to be rebuilt to see a newly installed IME.
        InputSource.invalidateBuiltInCache()
        onChange?(current.id, current.name)
    }
}
