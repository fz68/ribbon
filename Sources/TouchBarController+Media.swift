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

    /// Media poll interval: 30 s normally, 120 s once the last two polls found
    /// no media session at all.
    var mediaPollInterval: TimeInterval {
        mediaMissCount >= Theme.Timing.mediaMissThreshold ? Theme.Timing.mediaIdlePoll : Theme.Timing.mediaPoll
    }

    /// Updates the backoff counter and schedules the next poll.
    func finishMediaPoll(available: Bool) {
        mediaMissCount = available ? 0 : mediaMissCount + 1
        scheduleMediaPoll()
    }

    /// Schedules the next media poll with the current interval.
    func scheduleMediaPoll() {
        mediaTimer?.invalidate()
        guard !didShutdown else { return }
        let timer = Timer(timeInterval: mediaPollInterval, repeats: false) { [weak self] _ in
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
    }
}
