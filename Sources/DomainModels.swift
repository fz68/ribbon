import Cocoa

/// One AeroSpace workspace: its name, whether it is focused and the apps on it.
struct Workspace: Equatable {
    let name: String
    let isFocused: Bool
    let apps: [String]
}

/// One enabled keyboard input source as the system lists it.
struct InputSourceDescriptor: Equatable {
    let id: String
    let name: String
}

/// What the indicator line shows for an input source.
struct InputSourceAppearance {
    let show: Bool
    let color: NSColor?
    let rainbow: Bool
}

/// Whether the media state could be read and whether media is playing.
struct MediaState {
    let available: Bool
    let isPlaying: Bool
}

/// The battery percentage and whether the battery is charging.
struct BatteryState {
    let percent: Int
    let charging: Bool
}

/// A media transport command.
enum MediaCommand {
    case playPause
    case next
    case previous

    /// The verb the nowplaying-cli helper expects.
    var toolArgument: String {
        switch self {
        case .playPause: return "togglePlayPause"
        case .next: return "next"
        case .previous: return "previous"
        }
    }
}
