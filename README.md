# Ribbon

A Touch Bar ribbon for AeroSpace or Nehir.

Ribbon is a menu-bar-only macOS app that replaces the app strip on the Touch Bar with a single
full-width bar: media transport, one chip per workspace of the active window manager (AeroSpace
or Nehir), the front app name, brightness, volume, battery, a clock and a Control Strip toggle.
A 2 pt line along the very bottom edge shows the selected input source.

```
[prev] [play] [next] | 1 2 3 | Safari | sun- sun+ vol- vol+ [87%] 10月24 周六 11:04 [strip]
=====================================================================================================================
   2 pt input source line (hidden for plain keyboard layouts, rainbow for Doubao)
```

## Features

- Media previous / play-pause / next. Uses `nowplaying-cli` when it is installed and falls back to
  the standard media keys otherwise.
- One chip per workspace of the active window manager (AeroSpace or Nehir). Every chip has the same
  fixed 56 pt width, so the chips and the front app name keep their positions when apps open or
  close. A chip shows its workspace name, except that the 10th workspace reads `0`, like the 0 key
  that reaches it. The number of app icons that fit beside the name follows from that width, so a
  chip shows the first app open on its workspace: a one- or two-digit name leaves room for that
  icon, a three-digit name fills the chip, and a longer name truncates. The focused chip is a gold
  pill with dark text; each other chip keeps a stable colour derived from its workspace name. Tap a
  chip to switch workspace.
- Front app name, immediately right of the workspace chips.
- Brightness down / up (10% steps) and output volume down / up (5% steps). A small level pill
  flashes in the gap between the front app name and the brightness buttons on every step.
- Battery percentage, and a clock in Chinese format `M月d EEE HH:mm` (for example
  `10月24 周六 11:04`). The format and locale can be customized via `clock.json` or picked from
  `menu-bar icon > Clock Format` (see Configuration). The battery sits in a fixed 30 pt slot with
  its content right-aligned, so the buttons never move and a short reading such as `F` sits against
  the clock: it shows `87%`, `F` at full charge, `87⚡` while charging (the bolt replaces the `%`
  sign and follows the number) and `F⚡` when it is full and charging. The battery-clock gap is a
  constant 2 pt, unlike the 6 pt between the other controls. The clock is
  sized to its text: its width changes only when the date gains a digit (for example `1月1` ->
  `12月31`), which can shift the buttons left by a few points at midnight.
- Control Strip toggle. Full-width mode uses placement 1 and hides the right Control Strip; strip
  mode uses placement 0, keeps the Control Strip and hides media, app name, brightness and volume.
  The mode is persisted in UserDefaults under `controlStripVisible`.
- Input source line: 2 pt along one edge of the bar, bottom by default. It is hidden for plain keyboard
  layouts, drawn as a rainbow for Doubao, and drawn in a configurable colour for other input
  methods. The edge the line is drawn on is switchable between top and bottom from
  `menu-bar icon > IME Line Position`.
- The bar's content is flush with the Touch Bar's edges: there is no left or right margin, so the
  outermost controls sit exactly at the ends of the bar.

### Agent chip

The 56 pt chip left of the right cluster mirrors the local opencode 2.1.x/2.2.x background service.
Ribbon finds it through `~/.local/state/opencode/service.json`; nothing has to be installed besides
opencode itself, and the chip asks for no macOS permissions. The busy count follows the service's
own running-session set, polled every few seconds, because opencode 2.2.x stopped emitting
per-execution status events.

- Dim hollow dot: no session is running. Cyan border and a session-group count: sessions are busy
  (a subagent counts once, with the session that started it). Amber `!N`: a permission or form is
  waiting. Green: everything just went idle, for three seconds.
- Tap while a permission waits: an approval card with the session name and its place in the queue,
  then `允许` / `总是` / `拒绝` (allow once / always / deny). The second tap submits, and the card
  closes by itself after five seconds.
- Tap with nothing to approve: jump to the WezTerm pane hosting that session.
- Long-press (0.5 s) while a permission waits: skip to the next one. With nothing to approve, hold
  for 1.2 s to interrupt a session that is actually running; a waiting form does not block this.
- A form cannot be answered from the bar: the chip shows amber and a tap jumps to the session that
  is waiting for the answer.
- `Agent Chip` in the menu-bar menu turns the chip off and on without a restart.

## Keyboard shortcuts

Ribbon registers no keyboard shortcuts of its own: the workspace keys belong to the window manager,
so they keep working whether or not Ribbon is running. The bindings that mirror the usual AeroSpace
setup are:

| Action | AeroSpace | Nehir |
| --- | --- | --- |
| Switch to workspace 1-9 | `alt-1` .. `alt-9` | `Option+1` .. `Option+9` |
| Move the focused window to workspace 1-9 | `alt-shift-1` .. `alt-shift-9` | `Option+Shift+1` .. `Option+Shift+9` |
| Toggle between the last two workspaces | `alt-tab` | `Option+Tab` |

In Nehir they live in `~/.config/nehir/hotkeys.toml`:

```toml
[workspace]
switch = "Option+{N}"
moveTo = "Option+Shift+{N}"
backAndForth = "Option+Tab"
```

Nehir spells the modifiers `Control`, `Option`, `Shift`, `Command` and `Hyper`; `alt`, `cmd` and the
symbolic variants are not understood, and a line it cannot parse is dropped without a warning, so
a mistyped chord fails silently. `{N}` expands to the digits 1 to 9. A bare `Option` chord is
registered globally and therefore shadows the same chord inside other apps; pick a heavier modifier
if that gets in the way.

## Requirements

- A MacBook Pro with a Touch Bar. Tested on a 13-inch M1 2020 running macOS 15.8.2; the deployment
  target is macOS 13.0.
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) running, with its CLI at
  `/opt/homebrew/bin/aerospace` or `/usr/local/bin/aerospace`, **or**
  [Nehir](https://github.com/apphane-dev/nehir) 0.5.1 or newer with IPC enabled, and its `nehirctl`
  CLI in `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` or `~/bin`. Nehir has a
  workspace bar of its own in the menu bar; turn it off if you want the Touch Bar to be the only
  place you switch workspaces (see Known limits). A responding AeroSpace wins when both are
  installed, and a dead AeroSpace daemon falls back to Nehir.
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

Either window manager will do, as long as Ribbon starts after it. With Nehir, enable IPC before you
launch Ribbon: it probes for IPC once at launch and does not re-check.

Ribbon has no Dock icon. Its menu-bar item shows the Ribbon logo and offers Re-present, Refresh,
Show/Hide Control Strip, Set App+ControlStrip mode, Agent Chip, IME Color, Clock Format, and Quit.

## Configuration

There are three configuration files: the input source line at
`~/Library/Application Support/Ribbon/ime.json`, the clock display at
`~/Library/Application Support/Ribbon/clock.json`, and the agent chip switch at
`~/Library/Application Support/Ribbon/agent.json`. The agent file is a single object,
`{"enabled": true}`; set it to `false` (or use `menu-bar icon > Agent Chip`) to remove the chip
entirely. It is written back by the menu item and left untouched when it cannot be parsed.

### Input source line (`ime.json`)

It is created on first launch with a built-in default entry per enabled input source. The file is
written as pretty-printed JSON with sorted keys. If it cannot be parsed, Ribbon logs the error and
leaves the file untouched, so it can be repaired by hand; the app runs on the built-in defaults
meanwhile. Changes made from `menu-bar icon > IME Color` are written back to the same file. A
source that is not listed falls back to the built-in rule for its kind, and ultimately to `default`.

Schema:

| Key | Type | Meaning |
| --- | --- | --- |
| `linePosition` | string, optional | Which vertical edge of the Touch Bar row the input source line is drawn on: `top` or `bottom`, default `bottom` |
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
- `linePosition` accepts `top` or `bottom`; any other string value falls back to `bottom`, and an
  edit of the file is picked up by `menu-bar icon > Refresh`. The `menu-bar icon > IME Line
  Position` item writes this key.
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
- With Nehir, a refresh runs two queries:
  `nehirctl query workspaces --fields raw-name,display-name,is-current --format json` and
  `nehirctl query windows --fields workspace,app --format json`. The JSON is camelCase (`rawName`,
  `displayName`, `isCurrent`) with the arrays at `result.payload.workspaces` and
  `result.payload.windows`; the highlighted chip follows `isCurrent`. A tap resolves the chip label
  to a raw workspace id and calls `nehirctl workspace focus-name <raw-id>`. Changes are picked up
  from `nehirctl subscribe workspace-bar,windows-changed --no-send-initial`, falling back to 1 s
  polling when the subscription cannot be started. Measured on 2026-11-01, Nehir 0.5.1, IPC
  protocol version 6.
- Media uses `nowplaying-cli` (`get-raw`, `togglePlayPause`, `next`, `previous`), discovered in the
  Homebrew prefixes and then on `PATH`.

No SIP changes are needed, no Accessibility permission is requested, and the app is neither sandboxed
nor distributed through the App Store.

## Known limits

- The private DFRFoundation and DisplayServices APIs can break on any macOS update.
- Only one system-modal Touch Bar host can exist at a time; another app presenting one wins.
- Two window managers are supported and the backend is picked at launch: a responding AeroSpace
  daemon wins, otherwise Nehir, and with neither Ribbon keeps the AeroSpace placeholder behavior. A
  dead AeroSpace daemon falls back to Nehir.
- Nehir needs IPC enabled before Ribbon starts (Nehir Settings -> General, or `ipcEnabled = true`
  in the `[general]` table of `~/.config/nehir/settings.toml`; a bare top-level key does not enable
  IPC). Nehir writes its in-memory state back over `settings.toml` when it quits, so hand edits made
  while it is running are lost - quit Nehir, edit the file, then start Nehir again. Ribbon probes
  IPC once at launch, so enable IPC before launching (or relaunch Ribbon after enabling it).
- With IPC off entirely every `nehirctl` call fails with `transport_failure`, Ribbon gets no
  workspace list and the Touch Bar shows a single `?` placeholder chip. The 1 s polling fallback
  only covers a subscription that cannot be started; it does not recover a dead IPC endpoint.
- Nehir keeps a workspace bar of its own in the menu bar. To turn it off for good set
  `enabled = false` in the `[workspaceBar]` table of the same `settings.toml`, with the same
  quit-edit-restart order; `nehirctl command toggle-workspace-bar` only hides it for the current run
  and Nehir brings it back on restart. Ribbon looks for `nehirctl` in `PATH`, `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.local/bin` and `~/bin`. The `nehirctl` protocol is explicitly unstable, so a
  Nehir upgrade can break the integration.
- Nehir 0.5.1 expands the numeric hotkey groups in `hotkeys.toml` only up to workspace 9, so a tenth
  workspace has no keyboard shortcut of its own.
- AeroSpace has no window-closed event, so closing a background window can leave its icon state
  stale until the next event or the 30 s refresh, and a stale icon can stay visible until then.
- The agent chip couples to opencode 2.1.x's HTTP and event API and to the
  `~/.local/state/opencode/service.json` registration format. Neither promises stability across
  opencode versions, so a future release can break discovery, the event stream or approvals.
- Every chip is 56 pt wide so the row can be used by muscle memory. When the row outgrows the bar
  the chips compress evenly (down to 40 pt) and their names truncate, but they stay equal to each
  other; beyond roughly a dozen workspaces the row can still crowd the right cluster (a
  10-workspace row is 10*56 + 9*4 = 596 pt of the ~635 pt budget, and an 11th would need 656 pt).
  The text on a chip is the window manager's workspace name, except that the 10th workspace reads
  `0`.
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
- Nehir (https://github.com/apphane-dev/nehir) for workspace control and events as the second
  supported window manager.
- nowplaying-cli for media state.
- The Tokyo Night palette for colour inspiration.

Ribbon is not affiliated with Apple, AeroSpace or Pock.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 FanZhen.

Last reviewed 2026-11-01 against AeroSpace and Nehir 0.5.1 (IPC protocol version 6).
