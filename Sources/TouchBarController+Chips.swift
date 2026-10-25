import Cocoa

extension TouchBarController {
    /// Rebuilds the chip row, reusing the existing chips in place.
    ///
    /// Only the empty state and a chip-count change touch the view tree; a
    /// workspace data change is applied through `ChipView.update`, so the chips
    /// and their constraints survive a refresh or a tap.
    func rebuildChips() {
        guard !workspaces.isEmpty else {
            for view in leftStack.arrangedSubviews {
                leftStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            leftStack.addArrangedSubview(makePlaceholderChip())
            return
        }
        // A previous empty state leaves the "?" placeholder in the row.
        for view in leftStack.arrangedSubviews where !(view is ChipView) {
            leftStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let chips = leftStack.arrangedSubviews.compactMap { $0 as? ChipView }
        if chips.count > workspaces.count {
            for chip in chips[workspaces.count...] {
                leftStack.removeArrangedSubview(chip)
                chip.removeFromSuperview()
            }
        }
        // Chips are reused positionally; only a count change adds or removes views.
        for (index, workspace) in workspaces.enumerated() {
            if index < chips.count {
                chips[index].update(workspace: workspace, index: index)
            } else {
                leftStack.addArrangedSubview(makeChip(workspace, index: index))
            }
        }
    }

    func makeChip(_ workspace: Workspace, index: Int) -> ChipView {
        ChipView(
            workspace: workspace,
            index: index,
            target: self,
            action: #selector(chipTapped(_:))
        )
    }

    func makePlaceholderChip() -> NSButton {
        let grey = NSColor(argb: Theme.placeholderTint)
        let title = NSAttributedString(string: "?", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.chipFontSize, weight: .medium),
            .foregroundColor: grey,
        ])
        let button = NSButton(title: "?", target: self, action: #selector(refreshTapped))
        button.applyBarButtonStyle()
        button.attributedTitle = title
        button.wantsLayer = true
        button.layer?.cornerRadius = Theme.Layout.cornerRadius
        button.layer?.borderWidth = 1
        button.layer?.borderColor = grey.cgColor
        button.layer?.backgroundColor = NSColor(argb: Theme.controlBackground).cgColor
        button.widthAnchor.constraint(equalToConstant: Theme.Layout.chipMinWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: Theme.Layout.controlSize).isActive = true
        return button
    }

    @objc func chipTapped(_ sender: NSButton) {
        guard workspaces.indices.contains(sender.tag) else { return }
        let name = workspaces[sender.tag].name
        log("click workspace \(name)")
        workspaces = workspaces.map { Workspace(name: $0.name, isFocused: $0.name == name, apps: $0.apps) }
        rebuildChips()
        AeroSpace.focus(name) { succeeded in
            if !succeeded {
                log("workspace focus failed: \(name)")
            }
        }
        // Confirms the optimistic highlight against AeroSpace's own state. The event
        // stream normally lands first; this is the fallback for when it does not.
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.chipConfirmation) { [weak self] in
            self?.scheduleRefresh()
        }
    }

    @objc func refreshTapped() {
        refreshNow()
    }
}
