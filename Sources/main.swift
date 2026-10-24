import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = TouchBarController()
    private var statusItem: NSStatusItem?
    private var controlStripItem: NSMenuItem?
    private var inputSourceItem: NSMenuItem?
    private var imeColorItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("launched pid=\(ProcessInfo.processInfo.processIdentifier)")
        setupStatusItem()
        controller.onControlStripStateChanged = { [weak self] visible in
            self?.updateControlStripItemTitle(visible: visible)
        }
        controller.onInputSourceChanged = { [weak self] _, _ in
            self?.updateInputSourceItem()
            self?.rebuildIMEColorMenu()
        }
        updateControlStripItemTitle(visible: controller.controlStripVisible)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.controller.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "R"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Re-present", action: #selector(rePresent), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: ""))
        let strip = NSMenuItem(title: "Show Control Strip", action: #selector(toggleControlStrip), keyEquivalent: "")
        menu.addItem(strip)
        controlStripItem = strip
        menu.addItem(NSMenuItem(title: "Set App+ControlStrip mode", action: #selector(setAppWithControlStripMode), keyEquivalent: ""))

        // Read-out of the selected keyboard input source.
        let inputSource = NSMenuItem(title: "Input Source: -", action: nil, keyEquivalent: "")
        inputSource.isEnabled = false
        menu.addItem(inputSource)
        inputSourceItem = inputSource

        // Per source colour of the indicator line.
        let imeColor = NSMenuItem(title: "IME Color", action: nil, keyEquivalent: "")
        imeColor.submenu = NSMenu()
        menu.addItem(imeColor)
        imeColorItem = imeColor

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: ""))
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
        updateInputSourceItem()
        rebuildIMEColorMenu()
    }

    /// The menu item always names the action the next click performs.
    private func updateControlStripItemTitle(visible: Bool) {
        controlStripItem?.title = visible ? "Hide Control Strip" : "Show Control Strip"
    }

    /// Shows the selected input source in the menu.
    private func updateInputSourceItem() {
        guard let current = InputSource.current else {
            inputSourceItem?.title = "Input Source: unknown"
            return
        }
        inputSourceItem?.title = "Input Source: \(current.name) (\(current.id))"
    }

    /// Rebuilds the colour submenu from the enabled input sources. Every item is
    /// removed first, so rebuilding never duplicates a source.
    private func rebuildIMEColorMenu() {
        guard let submenu = imeColorItem?.submenu else { return }
        submenu.removeAllItems()
        let sources = InputSource.enabledSources.filter { !InputSource.isPlainKeyboardLayout(id: $0.id) }
        let nameCounts = Dictionary(grouping: sources, by: \.name).mapValues(\.count)
        for source in sources {
            // Two ids of one IME share a name, so the id is added to tell them apart.
            let title = (nameCounts[source.name] ?? 1) > 1 ? "\(source.name) [\(source.id)]" : source.name
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let choices = NSMenu()
            choices.addItem(makeColourChoice(title: "Rainbow", source: source, line: true, colour: nil, rainbow: true))
            choices.addItem(makeColourChoice(title: "No line", source: source, line: false, colour: nil, rainbow: false))
            choices.addItem(.separator())
            for entry in InputSource.palette {
                choices.addItem(makeColourChoice(title: entry.name, source: source, line: true, colour: entry.hex, rainbow: false))
            }
            item.submenu = choices
            submenu.addItem(item)
        }
    }

    /// One entry of the colour submenu.
    private func makeColourChoice(title: String, source: (id: String, name: String),
                                  line: Bool, colour: String?, rainbow: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setIMEAppearance(_:)), keyEquivalent: "")
        item.target = self
        let choice = IMEAppearanceChoice(id: source.id, name: source.name, line: line, colour: colour, rainbow: rainbow)
        item.representedObject = choice
        item.state = isSelected(choice) ? .on : .off
        return item
    }

    /// True when the stored configuration already uses this choice.
    private func isSelected(_ choice: IMEAppearanceChoice) -> Bool {
        guard let entry = InputSource.configuration().sources[choice.id] else { return false }
        if choice.rainbow { return entry.rainbow }
        if !choice.line { return !entry.line && !entry.rainbow }
        return entry.line && !entry.rainbow && entry.color == choice.colour
    }

    @objc private func rePresent() {
        controller.present()
    }

    @objc private func refresh() {
        TimeFormat.reload()
        controller.refreshNow()
    }

    @objc private func toggleControlStrip() {
        controller.toggleControlStrip()
    }

    @objc private func setAppWithControlStripMode() {
        controller.setAppWithControlStripMode()
    }

    /// Stores the picked colour and repaints the indicator line at once.
    @objc private func setIMEAppearance(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? IMEAppearanceChoice else { return }
        InputSource.setAppearance(id: choice.id, name: choice.name,
                                  show: choice.line, color: choice.colour, rainbow: choice.rainbow)
        controller.refreshInputSourceIndicator()
        updateInputSourceItem()
        rebuildIMEColorMenu()
        let style = choice.rainbow ? "rainbow" : (choice.line ? (choice.colour ?? "-") : "none")
        log("ime colour \(choice.id) -> \(style)")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The choice a menu item stands for. It travels to the action as the
/// represented object of the menu item.
private final class IMEAppearanceChoice: NSObject {
    let id: String
    let name: String
    let line: Bool
    let colour: String?
    let rainbow: Bool

    init(id: String, name: String, line: Bool, colour: String?, rainbow: Bool) {
        self.id = id
        self.name = name
        self.line = line
        self.colour = colour
        self.rainbow = rainbow
        super.init()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    delegate.controller.shutdown()
    NSApp.terminate(nil)
}
sigtermSource.resume()

app.run()
