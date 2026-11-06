import Foundation
import Darwin

/// Watches opencode's service registration file and reports the endpoint.
///
/// opencode rewrites `service.json` atomically (write a temp file, then rename
/// it over the old one), which leaves a descriptor on the old inode watching
/// nothing. A second source on the parent directory catches that replace, and
/// every event reinstalls the file source so the descriptor always follows the
/// current inode. Both sources share one serial queue, so callbacks arrive in
/// order and never on the main thread.
///
/// The registration directory only exists after opencode has run once, so when
/// it is missing the locator watches the nearest existing ancestor instead. The
/// first event there is what tells it the real directory may now exist, and it
/// then swaps in the real file and directory sources.
final class ServiceLocator {
    /// Called on the locator's serial queue with the endpoint, or nil when the
    /// file is missing or does not describe a usable service.
    var onEndpoint: ((ServiceEndpoint?) -> Void)?

    /// The fixed registration path. Injectable so tests never read the real one,
    /// and so a future config override does not need a new initializer.
    static let defaultPath = NSString(string: "~/.local/state/opencode/service.json")
        .expandingTildeInPath

    private let path: String
    private let queue = DispatchQueue(label: "local.ribbon.opencode.service-locator")
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    /// True while the directory source sits on an ancestor because the real
    /// directory does not exist yet.
    private var watchingAncestor = false
    /// Nested optional: nil means "nothing emitted yet", so the initial read
    /// always reports its state while later reads can be deduplicated.
    private var lastEmitted: ServiceEndpoint??
    private var started = false

    init(path: String = ServiceLocator.defaultPath) {
        self.path = path
    }

    deinit {
        // Kept as a safety net for a locator dropped without stop(); the cancel
        // handlers close the descriptors on the locator's queue.
        fileSource?.cancel()
        directorySource?.cancel()
    }

    /// Starts watching and performs one immediate read.
    ///
    /// Installing the directory source before the file source closes the window
    /// in which a replace could slip between the read and the watch.
    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.lastEmitted = nil
            self.installDirectorySource()
            self.installFileSource()
            self.readAndEmit()
        }
    }

    /// Cancels both sources. Pending callbacks already on the queue may still run.
    func stop() {
        queue.async {
            guard self.started else { return }
            self.started = false
            self.fileSource?.cancel()
            self.fileSource = nil
            self.directorySource?.cancel()
            self.directorySource = nil
        }
    }

    // MARK: - Sources

    /// Watches the registration directory, or the nearest existing ancestor
    /// while that directory is still missing.
    ///
    /// Every call reinstalls from scratch, which is what lets an ancestor event
    /// promote the watch to the real directory once it appears. Reinstalling is
    /// only ever driven by start() and by an observed event, so there is no
    /// retry loop.
    private func installDirectorySource() {
        directorySource?.cancel()
        directorySource = nil

        let target = (path as NSString).deletingLastPathComponent
        var candidate = target
        while true {
            if let source = makeDirectorySource(at: candidate) {
                directorySource = source
                watchingAncestor = candidate != target
                return
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty {
                // Reachable only if even "/" cannot be opened.
                log("opencode service directory unavailable: \(target)")
                watchingAncestor = false
                return
            }
            candidate = parent
        }
    }

    private func makeDirectorySource(at directory: String) -> DispatchSourceFileSystemObject? {
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleDirectoryEvent()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func installFileSource() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileSource = source
    }

    /// Handles a change in the watched directory (real or ancestor).
    ///
    /// A `.rename` or `.delete` event leaves the file descriptor on an inode
    /// that is no longer the registration file, so the file source is always
    /// replaced rather than reused; the read is cheap.
    private func handleDirectoryEvent() {
        guard started else { return }
        // While watching an ancestor, any event may be the creation of the real
        // directory: reinstall from scratch so the watch moves down to it.
        if watchingAncestor {
            installDirectorySource()
        }
        installFileSource()
        readAndEmit()
    }

    private func handleFileEvent() {
        guard started else { return }
        installFileSource()
        readAndEmit()
    }

    // MARK: - Reading

    private func readAndEmit() {
        let endpoint = Self.endpoint(atPath: path)
        if let previous = lastEmitted, previous == endpoint { return }
        lastEmitted = endpoint
        // The endpoint description is password-free by construction.
        if let endpoint {
            let host = endpoint.url.host ?? "?"
            let port = endpoint.url.port.map(String.init) ?? "?"
            // Host and port only: absoluteString would carry any userinfo a
            // malformed registration file might smuggle in.
            log("opencode service endpoint host=\(host) port=\(port) "
                + "version=\(endpoint.version) pid=\(endpoint.pid)")
        } else {
            log("opencode service endpoint unavailable")
        }
        onEndpoint?(endpoint)
    }

    /// Reads and decodes one registration file.
    ///
    /// Field-by-field parsing through JSONSerialization keeps a missing or
    /// oddly typed optional field (`pid` as a string, `version` absent) from
    /// rejecting the whole file: only `url` and `password` are required.
    static func endpoint(atPath path: String) -> ServiceEndpoint? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlString = object["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              // A registration URL never carries credentials; userinfo could
              // only leak a secret into logs or into the request itself.
              url.user == nil,
              url.password == nil,
              let password = object["password"] as? String,
              !password.isEmpty else {
            return nil
        }
        let version = object["version"] as? String ?? ""
        let pid = (object["pid"] as? NSNumber)?.int32Value ?? 0
        return ServiceEndpoint(url: url, password: password, version: version, pid: pid)
    }
}
