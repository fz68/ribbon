import Cocoa

extension TouchBarController {
    // MARK: - Input method indicator

    /// Redraws the indicator line from the current input source.
    func refreshInputSourceIndicator() {
        updateIMELine()
    }

    /// Updates the indicator line: its width follows the container and its look
    /// follows the configured entry of the selected source.
    func updateIMELine() {
        guard let current = InputSource.current else {
            imeLine.isHidden = true
            return
        }
        let appearance = InputSource.appearance(for: current.id)
        imeLine.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: 2)
        imeLine.isHidden = !appearance.show
        if appearance.show {
            applyIMELineStyle(color: appearance.color, rainbow: appearance.rainbow)
        }
    }

    /// Paints the line: a solid colour or a horizontal rainbow gradient.
    /// No animation runs, the line is static so it costs nothing.
    func applyIMELineStyle(color: NSColor?, rainbow: Bool) {
        if rainbow {
            let gradient = CAGradientLayer()
            gradient.colors = InputSource.rainbowHex.compactMap { NSColor(hex: $0)?.cgColor }
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.masksToBounds = true
            imeLine.layer = gradient
        } else {
            let solid = CALayer()
            solid.backgroundColor = color?.cgColor
            solid.masksToBounds = true
            imeLine.layer = solid
        }
    }

    /// Called when the selected input source changed.
    func handleInputSourceChange(id: String, name: String) {
        updateIMELine()
        logIMESource(prefix: "ime changed ->")
        onInputSourceChanged?(id, name)
    }

    /// Logs the current source and what the line shows for it.
    func logIMESource(prefix: String) {
        guard let current = InputSource.current else {
            log("\(prefix) none")
            return
        }
        let appearance = InputSource.appearance(for: current.id)
        let style: String
        if !appearance.show {
            style = "none"
        } else if appearance.rainbow {
            style = "rainbow"
        } else {
            style = appearance.color?.hexString ?? "-"
        }
        log("\(prefix) \(current.id) (\(current.name)) line=\(style)")
    }
}
