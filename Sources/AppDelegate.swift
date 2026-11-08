import Cocoa

/// The app delegate. It owns the Touch Bar controller and the menu-bar status item.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The controller the app presents for its whole lifetime, and the one `main.swift` shuts
    /// down on exit.
    public let controller = TouchBarController()
    private var statusItem: NSStatusItem?
    private var controlStripItem: NSMenuItem?
    private var inputSourceItem: NSMenuItem?
    private var imeColorItem: NSMenuItem?
    private var imeLinePositionItem: NSMenuItem?
    private var clockFormatItem: NSMenuItem?
    private var agentChipItem: NSMenuItem?

    /// The clock formats offered by the "Clock Format" submenu.
    private static let clockFormatPresets: [(format: String, locale: String)] = [
        ("M月d EEE HH:mm", "zh_CN"),
        ("MMM d EEE HH:mm", "en_US"),
        ("yyyy-MM-dd EEE HH:mm", "en_US"),
        ("HH:mm", "en_US"),
        ("h:mm a", "en_US"),
    ]

    /// Builds the menu-bar status item, wires the controller callbacks to it, and presents the
    /// bar a moment after launch so the launch path stays short.
    public func applicationDidFinishLaunching(_ notification: Notification) {
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
        updateAgentChipItemTitle(enabled: AgentConfig.isEnabled)
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.initialPresent) { [weak self] in
            self?.controller.present()
        }
    }

    /// Shuts the controller down, which stops its timers, monitors and agent bridge and dismisses
    /// the bar.
    public func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = StatusItemIcon.image {
            item.button?.image = icon
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = "Ribbon"
        } else {
            item.button?.title = "R"
        }
        let menu = NSMenu()
        menu.addItem(makeRePresentItem())
        menu.addItem(makeRefreshItem())
        menu.addItem(makeControlStripToggleItem())
        menu.addItem(makeStripModeItem())
        menu.addItem(makeAgentChipItem())
        menu.addItem(makeInputSourceItem())
        menu.addItem(makeIMEColorItem())
        menu.addItem(makeIMELinePositionItem())
        menu.addItem(makeClockFormatItem())
        menu.addItem(.separator())
        menu.addItem(makeQuitItem())
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
        updateInputSourceItem()
        rebuildIMEColorMenu()
        rebuildIMELinePositionMenu()
        rebuildClockFormatMenu()
    }

    private func makeRePresentItem() -> NSMenuItem {
        NSMenuItem(title: "Re-present", action: #selector(rePresent), keyEquivalent: "")
    }

    private func makeRefreshItem() -> NSMenuItem {
        NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "")
    }

    private func makeControlStripToggleItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Show Control Strip", action: #selector(toggleControlStrip), keyEquivalent: "")
        controlStripItem = item
        return item
    }

    private func makeStripModeItem() -> NSMenuItem {
        NSMenuItem(title: "Set App+ControlStrip mode", action: #selector(setAppWithControlStripMode), keyEquivalent: "")
    }

    /// The OpenCode agent chip switch. Like the Control Strip item, the title
    /// names the action the next click performs and reflects the live state
    /// without a restart.
    private func makeAgentChipItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Show Agent Chip", action: #selector(toggleAgentChip), keyEquivalent: "")
        agentChipItem = item
        return item
    }

    /// Read-out of the selected keyboard input source.
    private func makeInputSourceItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Input Source: unknown", action: nil, keyEquivalent: "")
        item.isEnabled = false
        inputSourceItem = item
        return item
    }

    /// Per source colour of the indicator line.
    private func makeIMEColorItem() -> NSMenuItem {
        let item = NSMenuItem(title: "IME Color", action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        imeColorItem = item
        return item
    }

    /// Which edge of the bar the indicator line is drawn on.
    private func makeIMELinePositionItem() -> NSMenuItem {
        let item = NSMenuItem(title: "IME Line Position", action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        imeLinePositionItem = item
        return item
    }

    /// Clock format presets and the config file shortcut.
    private func makeClockFormatItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Clock Format", action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        clockFormatItem = item
        return item
    }

    private func makeQuitItem() -> NSMenuItem {
        NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
    }

    /// The menu item always names the action the next click performs.
    private func updateControlStripItemTitle(visible: Bool) {
        controlStripItem?.title = visible ? "Hide Control Strip" : "Show Control Strip"
    }

    /// Same idiom for the agent chip switch.
    private func updateAgentChipItemTitle(enabled: Bool) {
        agentChipItem?.title = enabled ? "Hide Agent Chip" : "Show Agent Chip"
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

    /// Rebuilds the line position submenu. The checkmark always follows the
    /// stored configuration, so a hand edited file is shown as it is.
    private func rebuildIMELinePositionMenu() {
        guard let submenu = imeLinePositionItem?.submenu else { return }
        submenu.removeAllItems()
        for position in [InputSource.LinePosition.top, .bottom] {
            let title = position == .top ? "Top" : "Bottom"
            let item = NSMenuItem(title: title, action: #selector(setIMELinePosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
            item.state = position == InputSource.linePosition ? .on : .off
            submenu.addItem(item)
        }
    }

    /// One entry of the colour submenu.
    private func makeColourChoice(title: String, source: InputSourceDescriptor,
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

    /// Rebuilds the clock format submenu from the presets and the stored
    /// configuration. Every item is removed first, so rebuilding never
    /// duplicates an entry.
    private func rebuildClockFormatMenu() {
        guard let submenu = clockFormatItem?.submenu else { return }
        submenu.removeAllItems()
        for preset in Self.clockFormatPresets {
            let choice = ClockFormatChoice(format: preset.format, locale: preset.locale)
            let item = NSMenuItem(title: Self.clockFormatTitle(for: choice),
                                  action: #selector(setClockFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice
            item.state = isSelected(choice) ? .on : .off
            submenu.addItem(item)
        }
        // A hand-edited pair that matches no preset is shown for information only.
        let current = TimeFormat.currentConfiguration()
        if !Self.clockFormatPresets.contains(where: { $0.format == current.format && $0.locale == current.locale }) {
            let choice = ClockFormatChoice(format: current.format, locale: current.locale)
            let item = NSMenuItem(title: "Custom: \(Self.clockFormatTitle(for: choice))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.state = .on
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit clock.json…", action: #selector(openClockConfiguration(_:)), keyEquivalent: "")
        edit.target = self
        submenu.addItem(edit)
    }

    /// The menu title of a choice: the pair rendered for today, for example
    /// "10月24 周六 15:48". The presets are ICU patterns, so this stays
    /// `DateFormatter`; `Date.FormatStyle` cannot consume them.
    private static func clockFormatTitle(for choice: ClockFormatChoice) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: choice.locale)
        formatter.dateFormat = choice.format
        return formatter.string(from: Date())
    }

    /// True when the stored configuration already uses this clock format.
    private func isSelected(_ choice: ClockFormatChoice) -> Bool {
        let current = TimeFormat.currentConfiguration()
        return current.format == choice.format && current.locale == choice.locale
    }

    @objc private func rePresent() {
        controller.present()
    }

    @objc private func refresh() {
        TimeFormat.reload()
        rebuildClockFormatMenu()
        controller.refreshClock()
        // A hand edited ime.json is picked up here, not only on the next launch.
        InputSource.invalidateConfiguration()
        controller.refreshInputSourceIndicator()
        rebuildIMEColorMenu()
        rebuildIMELinePositionMenu()
        controller.refreshNow()
    }

    @objc private func toggleControlStrip() {
        controller.toggleControlStrip()
    }

    /// Flips the agent chip switch, persists it, and applies it live.
    @objc private func toggleAgentChip() {
        let enabled = !AgentConfig.isEnabled
        guard AgentConfig.setEnabled(enabled) else {
            log("agent chip config write failed")
            return
        }
        updateAgentChipItemTitle(enabled: enabled)
        controller.applyAgentEnabled(enabled)
        log("agent chip enabled=\(enabled ? 1 : 0)")
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

    /// Stores the picked edge and repaints the indicator line at once.
    @objc private func setIMELinePosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = InputSource.LinePosition(rawValue: raw) else { return }
        InputSource.setLinePosition(position)
        controller.refreshInputSourceIndicator()
        rebuildIMELinePositionMenu()
        log("ime line position -> \(position.rawValue)")
    }

    /// Stores the picked clock format and repaints the clock at once.
    @objc private func setClockFormat(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ClockFormatChoice else { return }
        TimeFormat.apply(format: choice.format, locale: choice.locale)
        controller.refreshClock()
        rebuildClockFormatMenu()
        log("clock format -> \(choice.format) (\(choice.locale))")
    }

    /// Opens clock.json in whatever app owns JSON files.
    @objc private func openClockConfiguration(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: TimeFormat.configurationPath))
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

/// The clock format a menu item stands for. Like IMEAppearanceChoice it travels
/// to the action as the represented object of the menu item.
private final class ClockFormatChoice: NSObject {
    let format: String
    let locale: String

    init(format: String, locale: String) {
        self.format = format
        self.locale = locale
        super.init()
    }
}
