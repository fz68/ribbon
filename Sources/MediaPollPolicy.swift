import Foundation

/// Backoff policy for the media poll.
///
/// Every poll costs a process spawn, so a machine with no media session at all
/// would pay that price for nothing. Each consecutive miss lengthens the wait
/// up to the idle interval, and any successful poll resets the policy so a
/// session that comes back is picked up at the normal rate again.
struct MediaPollPolicy: Equatable {
    let missCount: Int
    static let initial = MediaPollPolicy(missCount: 0)
    var interval: TimeInterval { missCount >= Theme.Timing.mediaMissThreshold ? Theme.Timing.mediaIdlePoll : Theme.Timing.mediaPoll }
    func recording(available: Bool) -> MediaPollPolicy { MediaPollPolicy(missCount: available ? 0 : missCount + 1) }
}
