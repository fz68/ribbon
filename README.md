# Ribbon

A Touch Bar ribbon for AeroSpace.

Ribbon is a menu-bar-only macOS app that replaces the app strip on the Touch Bar with a single
full-width bar: media transport, one chip per AeroSpace workspace, the front app name, brightness,
volume, battery, a clock and a Control Strip toggle. A 2 pt line along the very bottom edge shows
the selected input source.

```
 [prev] [play] [next] | 1 [icons] 2 [icons] 3 [icons] | Safari | sun- sun+ vol- vol+ 87% 10月24 周六 11:04 [strip]
 =================================================================================================================
   2 pt input source line (hidden for plain keyboard layouts, rainbow for Doubao)
```

## Features

- Media previous / play-pause / next. Uses `nowplaying-cli` when it is installed and falls back to
  the standard media keys otherwise.
- One chip per AeroSpace workspace: workspace name plus up to three app icons. The focused chip is
  yellow, the others cycle through a 12-colour palette. Tap a chip to switch workspace.
- Front app name, immediately right of the workspace chips.
- Brightness down / up (10% steps) and output volume down / up (5% steps).
- Battery percentage, and a clock in Chinese format `M月d EEE HH:mm` (for example
  `10月24 周六 11:04`). The format and locale can be customized via `clock.json` or picked from
  `menu-bar icon > Clock Format` (see Configuration).
- Control Strip toggle. Full-width mode uses placement 1 and hides the right Control Strip; strip
  mode uses placement 0, keeps the Control Strip and hides media, app name, brightness and volume.
  The mode is persisted in UserDefaults under `controlStripVisible`.
- Input source line: 2 pt along the bottom edge of the bar. It is hidden for plain keyboard
  layouts, drawn as a rainbow for Doubao, and drawn in a configurable colour for other input
  methods.

## Requirements

- A MacBook Pro with a Touch Bar. Tested on a 13-inch M1 2020 running macOS 15.8.2; the deployment
  target is macOS 13.0.
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) running, with its CLI at
  `/opt/homebrew/bin/aerospace` or `/usr/local/bin/aerospace`.
- Optional: `nowplaying-cli` for media state (`brew install nowplaying-cli`). Without it, Ribbon
  posts the system media keys instead.
- Xcode or the Command Line Tools with Swift 5.9 or newer (`swift`, `codesign`).

## Build

```sh
swift build    # build the package in debug configuration
make           # build the release app bundle at build/Ribbon.app
make run       # kill a running Ribbon, then open build/Ribbon.app
make test      # run the test suite (swift test --no-parallel)
make coverage  # run the tests with coverage and print an llvm-cov report
make lint      # build Sources and Tests with -warnings-as-errors
make dmg       # stage build/dmg and package build/Ribbon-<version>.dmg
make clean     # remove build/ and .build/
```

Ribbon is a SwiftPM package (`Package.swift`): `RibbonCore` is the library, `Ribbon` the
executable and `RibbonTests` the test target. The Makefile is a thin facade over SwiftPM: `make`
runs `swift build -c release`, copies `.build/release/Ribbon` and `Resources/Info.plist` into
`build/Ribbon.app` and ad-hoc signs it. There is no Xcode project. `make dmg` additionally stages
the bundle and an `Applications` symlink into `build/dmg`, then packs it into
`build/Ribbon-<version>.dmg` with `hdiutil create -format UDZO`; the version comes from
`Resources/Info.plist`.

The app icon is generated during `make`: `Tools/make-icons.swift` renders
`Resources/RibbonTemplate.svg` into `Resources/Ribbon.icns` inside the bundle.

`make test` runs `swift test --no-parallel`; the tests are serialized because they share a
process-global log path, and a non-zero exit fails the target. `make coverage` re-runs them with
`--enable-code-coverage`, merges the profile with `llvm-profdata` and prints an `llvm-cov report`
covering `Sources/` and `Tests/`. `make lint` builds the package and the test targets with
`-warnings-as-errors`, so any new compiler diagnostic fails the build. CI runs `make lint`,
`make test` and `make all` on an arm64 macOS runner (`.github/workflows/ci.yml`).

## Install

Copy the built bundle to `/Applications` or `~/Applications`:

```sh
cp -R build/Ribbon.app /Applications/
open /Applications/Ribbon.app
```

If you built a release image with `make dmg`, mount `build/Ribbon-<version>.dmg` and drag
`Ribbon.app` into `Applications`.

To start at login, add a LaunchAgent such as `~/Library/LaunchAgents/local.fanzhen.ribbon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.fanzhen.ribbon</string>
    <key>ProgramArguments</key><array><string>/Applications/Ribbon.app/Contents/MacOS/Ribbon</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
```

Alternatively let AeroSpace start it:

```toml
after-startup-command = ['exec-and-forget /bin/bash -c "sleep 1; open /Applications/Ribbon.app"']
```

Ribbon has no Dock icon. Its menu-bar item shows the Ribbon logo and offers Re-present, Refresh,
Show/Hide Control Strip, Set App+ControlStrip mode, IME Color, Clock Format, and Quit.

## Configuration

There are two configuration files: the input source line at
`~/Library/Application Support/Ribbon/ime.json` and the clock display at
`~/Library/Application Support/Ribbon/clock.json`.

### Input source line (`ime.json`)

It is created on first launch with a built-in default entry per enabled input source. The file is
written as pretty-printed JSON with sorted keys. If it cannot be parsed, Ribbon logs the error, falls
back to the built-in defaults and rewrites the file. Changes made from `menu-bar icon > IME Color`
are written back to the same file. A source that is not listed falls back to the built-in rule for
its kind, and ultimately to `default`.

Schema:

| Key | Type | Meaning |
| --- | --- | --- |
| `default` | object | Fallback entry for input sources without an entry of their own |
| `default.name` | string, optional | Only source entries normally carry a name; informational |
| `default.line` | bool | Whether the line is drawn |
| `default.color` | string | Solid colour as `#RRGGBB` |
| `default.rainbow` | bool | Draw the line as a rainbow gradient instead of a solid colour |
| `sources` | object | Per-source entries, keyed by input source id |
| `sources.<id>` | object | Same fields as `default` |

Example:

```json
{
  "default" : { "color" : "#4FA3FF", "line" : true, "rainbow" : false },
  "sources" : {
    "com.apple.keylayout.ABC" : { "color" : "#4FA3FF", "line" : false, "name" : "ABC", "rainbow" : false },
    "com.apple.inputmethod.SCIM.ITABC" : { "color" : "#B388FF", "line" : true, "name" : "Pinyin - Simplified", "rainbow" : false },
    "com.bytedance.inputmethod.doubaoime" : { "color" : "#4FA3FF", "line" : true, "name" : "Doubao", "rainbow" : true }
  }
}
```

Notes:

- `rainbow: true` takes precedence over `color`.
- A plain keyboard layout (any id starting with `com.apple.keylayout.`) never draws the line, even
  when its entry has `line: true`.
- `color` must be a six-digit `#RRGGBB` string; anything else is treated as no colour.
- The palette used by the in-app menu and by the generated defaults is Red `#FF5F57`, Orange
  `#FF8C42`, Yellow `#FFD60A`, Green `#4CD964`, Cyan `#40C8E0`, Blue `#4FA3FF`, Purple `#B388FF`.

### Clock format (`clock.json`)

The clock display is configured at `~/Library/Application Support/Ribbon/clock.json` or picked from
the status menu via `menu-bar icon > Clock Format`. The file is created on first launch with the
built-in defaults and written as pretty-printed JSON with sorted keys.

| Key | Type | Meaning |
| --- | --- | --- |
| `format` | string | ICU date format pattern, default `M月d EEE HH:mm` |
| `locale` | string | BCP 47 locale identifier, default `zh_CN` |

Example:

```json
{
  "format" : "yyyy-MM-dd HH:mm",
  "locale" : "en_US"
}
```

Notes:

- A malformed file is noted in `~/Library/Logs/ribbon.log` and the built-in defaults are used; the
  file itself is never rewritten or deleted by the app.
- `menu-bar icon > Clock Format` offers five presets (Chinese default, `MMM d EEE HH:mm`,
  `yyyy-MM-dd EEE HH:mm`, `HH:mm` and `h:mm a`), each shown with today's date. Picking one writes
  `clock.json` and repaints the clock at once. A pair that matches no preset is shown as a checked
  `Custom:` entry.
- `menu-bar icon > Clock Format > Edit clock.json…` opens the file in the default editor. Hand
  edits apply after a relaunch, or immediately from `menu-bar icon > Refresh`.
- A custom `format` is rendered verbatim. The built-in `星期` -> `周X` abbreviation only applies to
  the default pattern, so `EEEE` with the default locale may produce `星期六`.

The log is written to `~/Library/Logs/ribbon.log`; follow it with `tail -f`.

## How it works

Ribbon creates an `NSTouchBar` and presents it system-modally with the private DFRFoundation API
`presentSystemModalTouchBar:placement:systemTrayItemIdentifier:`. That lets a normal AppKit view
hierarchy be hosted in the bar instead of only `NSTouchBarItem`s.

- Brightness uses the private DisplayServices framework (`DisplayServicesGetBrightness`,
  `DisplayServicesSetBrightness`).
- Volume uses `osascript` on a background queue.
- Battery uses `pmset -g batt`.
- The clock is formatted with `DateFormatter`; no process is spawned. The pattern and locale come
  from `clock.json`; the `Clock Format` menu rewrites the file and repaints the clock at once.
- Workspaces come from the AeroSpace CLI: a refresh runs two calls, `list-workspaces` and
  `list-windows`. `aerospace subscribe` events (focused workspace, window detected, focused monitor,
  focus changed) trigger refreshes, and a 30 s timer re-reads state when no event arrives.
- Media uses `nowplaying-cli` (`get-raw`, `togglePlayPause`, `next`, `previous`), discovered in the
  Homebrew prefixes and then on `PATH`.

No SIP changes are needed, no Accessibility permission is requested, and the app is neither sandboxed
nor distributed through the App Store.

## Known limits

- The private DFRFoundation and DisplayServices APIs can break on any macOS update.
- Only one system-modal Touch Bar host can exist at a time; another app presenting one wins.
- AeroSpace only. There is no support for other window managers.
- AeroSpace has no window-closed event, so closing a background window can leave its icon visible
  until the next event or the 30 s refresh.
- The full-width layout assumes the 13-inch panel: the app requests 1004 pt and the system grants
  996 pt. Strip mode uses 680 pt. The 1085 pt panels of the 15-inch and 16-inch models are untested.
- On some macOS 26/27 builds the Touch Bar can stop updating; `killall ControlStrip` and
  re-presenting from the menu usually restores it.
- Only Apple silicon is supported; SwiftPM builds for the host architecture, so the Intel Touch Bar
  models (2016-2019 13-inch and 15-inch) are untested and unsupported.
- The build is ad-hoc signed and not notarized. A downloaded copy is blocked by Gatekeeper until
  you choose Open Anyway, or you can run `xattr -d com.apple.quarantine /Applications/Ribbon.app`.

## Credits

- PockV2 (MIT, Copyright (c) 2020 Konstantin Touev) for the private NSTouchBar declarations and the
  system-modal presentation approach. See `THIRD_PARTY_NOTICES.md`.
- ShowyEdge for the input-source line inspiration.
- AeroSpace for workspace control and events.
- nowplaying-cli for media state.
- The Tokyo Night palette for colour inspiration.

Ribbon is not affiliated with Apple, AeroSpace or Pock.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 FanZhen.
