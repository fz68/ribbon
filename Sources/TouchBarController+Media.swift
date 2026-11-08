import Cocoa

extension TouchBarController {
    // MARK: - Media transport

    @objc func mediaPrevious() {
        Media.command(.previous)
        log("media prev")
    }

    @objc func mediaNext() {
        Media.command(.next)
        log("media next")
    }

    @objc func mediaPlayPause() {
        Media.command(.playPause)
        // Flip optimistically, the poll corrects it a moment later.
        setMediaIcon(playing: !(mediaIsPlaying ?? false))
        log("media play-pause")
    }

    /// Polls the playback state off the main thread and updates the icon on main.
    func pollMediaState() {
        guard !didShutdown else { return }
        mediaQueue.async { [weak self] in
            guard let self else { return }
            let state = Media.state()
            DispatchQueue.main.async {
                guard !self.didShutdown else { return }
                guard let state else {
                    self.setMediaIcon(playing: nil)
                    self.finishMediaPoll(available: false)
                    return
                }
                self.setMediaIcon(playing: state.available ? state.isPlaying : nil)
                self.finishMediaPoll(available: state.available)
                if state.available, state.isPlaying != self.lastLoggedMediaState {
                    self.lastLoggedMediaState = state.isPlaying
                    log("media state playing=\(state.isPlaying)")
                }
            }
        }
    }

    /// Dims the transport row when no media session is reporting. The buttons
    /// stay enabled: the media-key fallback may still control something.
    func setMediaIdle(_ idle: Bool) {
        let alpha: CGFloat = idle ? 0.45 : 1
        // Skip identical writes, matching the other label refreshes. The stack
        // covers all three buttons and is hidden in strip mode anyway.
        guard mediaStack.alphaValue != alpha else { return }
        mediaStack.alphaValue = alpha
        // The dimming is invisible to VoiceOver, so the same transition says it
        // out loud: pointed at no session, these keys still reach whatever the
        // system's media key does.
        let help: String? = idle ? "No media session" : nil
        for button in [mediaPrevButton, mediaPlayPauseButton, mediaNextButton] {
            button.setAccessibilityHelp(help)
        }
    }

    /// Updates the backoff counter and schedules the next poll.
    func finishMediaPoll(available: Bool) {
        setMediaIdle(!available)
        mediaPoll = mediaPoll.recording(available: available)
        scheduleMediaPoll()
    }

    /// Schedules the next media poll with the current interval.
    func scheduleMediaPoll() {
        mediaTimer?.invalidate()
        guard !didShutdown else { return }
        let timer = Timer(timeInterval: mediaPoll.interval, repeats: false) { [weak self] _ in
            self?.pollMediaState()
        }
        RunLoop.main.add(timer, forMode: .common)
        mediaTimer = timer
    }

    /// Shows the play, pause or neutral symbol. nil means the state is unknown.
    func setMediaIcon(playing: Bool?) {
        guard mediaIsPlaying != playing else { return }
        mediaIsPlaying = playing
        let symbol: String
        switch playing {
        case .some(true): symbol = "pause.fill"
        case .some(false): symbol = "play.fill"
        case .none: symbol = "playpause"
        }
        if let image = SymbolImage.make(symbol, accessibility: "Play / pause", logContext: "play/pause") {
            mediaPlayPauseButton.image = image
            mediaPlayPauseButton.imageScaling = .scaleProportionallyDown
        }
        // The symbol is the only cue that the button changed, and a VoiceOver
        // user never sees it, so the label follows the same three cases.
        mediaPlayPauseButton.setAccessibilityLabel(Self.mediaPlayPauseLabel(playing: playing))
    }

    /// The words for the action the button performs. Pure, so all three cases
    /// are testable without the bar.
    ///
    /// The label names what activating does, not what is playing: while media
    /// plays the button draws a pause glyph and pauses it, so it reads "Pause".
    static func mediaPlayPauseLabel(playing: Bool?) -> String {
        switch playing {
        case .some(true): return "Pause"
        case .some(false): return "Play"
        case .none: return "Play / pause"
        }
    }
}
