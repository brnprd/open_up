# OPEN_UP

A Spotlight-style "open with…" picker for macOS, in a black-and-white terminal style.
Double-click a file and OPEN_UP guesses the app; press Enter, or pick another.

One native app, no server: the Swift helper ([helper/main.swift](helper/main.swift)) holds the rules,
learning and app index, and shows the bundled UI ([ui/](ui/)) in its own windows. The pages reach the app's data
through a private message bridge, not the network, so nothing listens on a port.

Your rules and learned picks are saved in `~/Library/Application Support/OPEN_UP/state.json`.

## Install

| | |
|---|---|
| `./install.sh` | build and install to `~/Applications` |
| `./package.sh` | build `dist/OPEN_UP-<version>.dmg` (universal, drag-to-install) |

Needs the Xcode command line tools (`swiftc`). The DMG is ad-hoc signed, not notarized, so on another Mac
the first launch needs right-click → Open (or System Settings → Privacy & Security → Open Anyway).

## Use

| | |
|---|---|
| `open ~/Applications/OPEN_UP.app` | settings: rank apps per extension |
| `./bin/openup file.pdf` | show the picker for a file |
| `./bin/openup --default md pdf txt` | make OPEN_UP the double-click app for those types |

Picker keys: `↑↓` move · `⏎` open · `⇧⏎` open and always use this app · `⇥` other apps · type to search ·
`esc` or click away to close.

**How the guess is ranked:** your ranked apps for the extension → `*` (any-type) rules → apps you've picked
before (more often and recently ranks higher) → macOS's suggestions.

Undo a default: Finder → Get Info → Open with → choose an app → Change All.

## Development

- Edit `ui/*.html` / `ui/theme.css` or `helper/main.swift`, then `./install.sh`.
- `OpenUp --snapshot pick|settings out.png [file]` renders a page offscreen to a PNG for checking the look.
